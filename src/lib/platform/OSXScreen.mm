/*
 * Deskflow -- mouse and keyboard sharing utility
 * SPDX-FileCopyrightText: (C) 2025 - 2026 Deskflow Developers
 * SPDX-FileCopyrightText: (C) 2012 - 2016 Synergy App Ltd
 * SPDX-FileCopyrightText: (C) 2004 Chris Schoeneman
 * SPDX-License-Identifier: GPL-2.0-only WITH LicenseRef-OpenSSL-Exception
 */

#include "platform/OSXScreen.h"

#include "arch/Arch.h"
#include "arch/ArchException.h"
#include "base/Event.h"
#include "base/EventQueue.h"
#include "base/IEventQueue.h"
#include "base/Log.h"
#include "base/TMethodJob.h"
#include "client/Client.h"
#include "common/ExitCodes.h"
#include "common/Settings.h"
#include "deskflow/ClientApp.h"
#include "deskflow/Clipboard.h"
#include "deskflow/DisplayInvalidException.h"
#include "deskflow/KeyMap.h"
#include "mt/CondVar.h"
#include "mt/Lock.h"
#include "mt/Mutex.h"
#include "mt/Thread.h"
#include "platform/OSXClipboard.h"
#include "platform/OSXEventQueueBuffer.h"
#include "platform/OSXKeyState.h"
#include "platform/OSXMediaKeySupport.h"
#include "platform/OSXPasteboardPeeker.h"
#include "platform/OSXScreenSaver.h"

#include "deskflow/ipc/CoreIpc.h"

#include <AppKit/NSEvent.h>
#include <AppKit/NSWorkspace.h>
#include <AvailabilityMacros.h>
#include <IOKit/hidsystem/event_status_driver.h>
#include <dispatch/dispatch.h>
#include <libproc.h>
#include <mach-o/dyld.h>
#include <math.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

// The following creates a section that tells Mac OS X
// that it is OK to let us inject input in the login screen.
// Just the name of the section is important, not its contents.
__attribute__((used)) __attribute__((section("__CGPreLoginApp,__cgpreloginapp"))) static const char magic_section[] =
    "";
////////////////////////////////////////////////////////////

// This isn't in any Apple SDK that I know of as of yet.
enum
{
  kDeskflowEventMouseScroll = 11,
  kDeskflowMouseScrollAxisX = 'saxx',
  kDeskflowMouseScrollAxisY = 'saxy'
};

static const double kCarbonLoopWaitTimeout = 10.0;

// Synthetic mouse button and drag events require event numbers on macOS 27 and later.
static inline bool needsEventNumber()
{
  return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27;
}

int getSecureInputEventPID();
std::string getProcessName(int pid);

// TODO: upgrade deprecated function usage in these functions.
void setZeroSuppressionInterval();
void avoidSupression();
void logCursorVisibility();
void avoidHesitatingCursor();

//
// OSXScreen
//

bool OSXScreen::s_testedForGHOM = false;
bool OSXScreen::s_hasGHOM = false;

OSXScreen::OSXScreen(IEventQueue *events, bool isPrimary, bool enableLangSync)
    : PlatformScreen(events),
      m_isPrimary(isPrimary),
      m_isOnScreen(m_isPrimary),
      m_cursorPosValid(false),
      MouseButtonEventMap(NumButtonIDs),
      m_cursorHidden(false),
      m_keyState(nullptr),
      m_sequenceNumber(0),
      m_screensaver(nullptr),
      m_screensaverNotify(false),
      m_ownClipboard(false),
      m_clipboardTimer(nullptr),
      m_axTimer(nullptr),
      m_hiddenWindow(nullptr),
      m_userInputWindow(nullptr),
      m_switchEventHandlerRef(0),
      m_pmMutex(new Mutex),
      m_pmWatchThread(nullptr),
      m_pmThreadReady(new CondVar<bool>(m_pmMutex, false)),
      m_pmRootPort(0),
      m_activeModifierHotKey(0),
      m_activeModifierHotKeyMask(0),
      m_eventTapPort(nullptr),
      m_eventTapRLSR(nullptr),
      m_lastClickTime(0),
      m_clickState(1),
      m_lastSingleClickXCursor(0),
      m_lastSingleClickYCursor(0),
      m_events(events),
      m_impl(nullptr)
{
  m_displayID = CGMainDisplayID();
  if (!updateScreenShape(m_displayID, 0)) {
    throw DisplayInvalidException("failed to initialize screen shape");
  }

  try {
    m_screensaver = new OSXScreenSaver(m_events, getEventTarget());
    m_keyState = new OSXKeyState(m_events, AppUtil::instance().getKeyboardLayoutList(), enableLangSync);

    if (Settings::value(Settings::Core::PreventSleep).toBool()) {
      m_powerManager.disableSleep();
    }

    // only needed when running as a server.
    if (m_isPrimary) {
      // we can't pass options to show the dialog, this must be done by the gui.
      if (!AXIsProcessTrusted()) {
        throw std::runtime_error("assistive devices does not trust this process, allow it in system settings.");
      }
    }

    // install display manager notification handler
    CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, this);

    // install fast user switching event handler
    EventTypeSpec switchEventTypes[2];
    switchEventTypes[0].eventClass = kEventClassSystem;
    switchEventTypes[0].eventKind = kEventSystemUserSessionDeactivated;
    switchEventTypes[1].eventClass = kEventClassSystem;
    switchEventTypes[1].eventKind = kEventSystemUserSessionActivated;
    EventHandlerUPP switchEventHandler = NewEventHandlerUPP(userSwitchCallback);
    InstallApplicationEventHandler(switchEventHandler, 2, switchEventTypes, this, &m_switchEventHandlerRef);
    DisposeEventHandlerUPP(switchEventHandler);

    constructMouseButtonEventMap();

    // watch for requests to sleep
    m_events->addHandler(EventTypes::OsxScreenConfirmSleep, getEventTarget(), [this](const auto &e) {
      handleConfirmSleep(e);
    });

    // create thread for monitoring system power state.
    *m_pmThreadReady = false;
    m_carbonLoopMutex = new Mutex();
    m_carbonLoopReady = new CondVar<bool>(m_carbonLoopMutex, false);
    LOG_DEBUG("starting watchSystemPowerThread");
    m_pmWatchThread = new Thread(new TMethodJob<OSXScreen>(this, &OSXScreen::watchSystemPowerThread));
  } catch (...) {
    m_events->removeHandler(EventTypes::OsxScreenConfirmSleep, getEventTarget());
    if (m_switchEventHandlerRef != 0) {
      RemoveEventHandler(m_switchEventHandlerRef);
    }

    CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, this);

    NSNotificationCenter *sessionCenter = [[NSWorkspace sharedWorkspace] notificationCenter];
    if (m_sessionResignObserver != nullptr) {
      [sessionCenter removeObserver:(__bridge id)m_sessionResignObserver];
      m_sessionResignObserver = nullptr;
    }
    if (m_sessionActiveObserver != nullptr) {
      [sessionCenter removeObserver:(__bridge id)m_sessionActiveObserver];
      m_sessionActiveObserver = nullptr;
    }

    delete m_keyState;
    delete m_screensaver;
    throw;
  }

  // install event handlers
  m_events->addHandler(EventTypes::System, m_events->getSystemTarget(), [this](const auto &e) {
    handleSystemEvent(e);
  });

  // Watch session lock/unlock and fast user switching: macOS restores the
  // cursor's visibility and mouse-coupling across these transitions, which
  // desyncs the state left() established while the pointer is on a client
  // (ghost cursor moving in sync with the client's, clicks only on the
  // client). Re-assert the capture right away and for a few seconds, since
  // macOS may restore its cursor state after the notification.
  auto sessionChangeBlock = ^(NSNotification *note) {
    LOG_DEBUG("session change notification: %s", note.name.UTF8String);
    m_reassertCursorUntil = Arch::time() + 3.0;
    reassertCursorCapture();
  };
  NSNotificationCenter *sessionCenter = [[NSWorkspace sharedWorkspace] notificationCenter];
  // The notification center retains each token until removeObserver, so the
  // raw pointers below stay valid for the lifetime of this object even though
  // addObserverForName returns an autoreleased token (this file is not ARC).
  m_sessionResignObserver = (__bridge void *)[sessionCenter
      addObserverForName:NSWorkspaceSessionDidResignActiveNotification
                  object:nil
                   queue:nil
              usingBlock:sessionChangeBlock];
  m_sessionActiveObserver = (__bridge void *)[sessionCenter
      addObserverForName:NSWorkspaceSessionDidBecomeActiveNotification
                  object:nil
                   queue:nil
              usingBlock:sessionChangeBlock];

  // install the platform event queue
  m_events->adoptBuffer(new OSXEventQueueBuffer(m_events));
}

OSXScreen::~OSXScreen()
{
  disable();

  NSNotificationCenter *sessionCenter = [[NSWorkspace sharedWorkspace] notificationCenter];
  if (m_sessionResignObserver != nullptr) {
    [sessionCenter removeObserver:(__bridge id)m_sessionResignObserver];
    m_sessionResignObserver = nullptr;
  }
  if (m_sessionActiveObserver != nullptr) {
    [sessionCenter removeObserver:(__bridge id)m_sessionActiveObserver];
    m_sessionActiveObserver = nullptr;
  }

  m_events->adoptBuffer(nullptr);
  m_events->removeHandler(EventTypes::System, m_events->getSystemTarget());

  if (m_pmWatchThread) {
    // make sure the thread has setup the runloop.
    {
      Lock lock(m_pmMutex);
      while (!(bool)*m_pmThreadReady) {
        m_pmThreadReady->wait();
      }
    }

    // now exit the thread's runloop and wait for it to exit
    LOG_DEBUG("stopping watchSystemPowerThread");
    CFRunLoopStop(m_pmRunloop);
    m_pmWatchThread->wait();
    delete m_pmWatchThread;
    m_pmWatchThread = nullptr;
  }
  delete m_pmThreadReady;
  delete m_pmMutex;

  m_events->removeHandler(EventTypes::OsxScreenConfirmSleep, getEventTarget());

  RemoveEventHandler(m_switchEventHandlerRef);

  CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, this);

  delete m_keyState;
  delete m_screensaver;

  delete m_carbonLoopMutex;
  delete m_carbonLoopReady;
}

void *OSXScreen::getEventTarget() const
{
  return const_cast<OSXScreen *>(this);
}

bool OSXScreen::getClipboard(ClipboardID, IClipboard *dst) const
{
  Clipboard::copy(dst, &m_pasteboard);
  return true;
}

void OSXScreen::getShape(int32_t &x, int32_t &y, int32_t &w, int32_t &h) const
{
  x = m_x;
  y = m_y;
  w = m_w;
  h = m_h;
}

void OSXScreen::getCursorPos(int32_t &x, int32_t &y) const
{
  CGEventRef event = CGEventCreate(nullptr);
  CGPoint mouse = CGEventGetLocation(event);
  x = mouse.x;
  y = mouse.y;
  m_cursorPosValid = true;
  m_xCursor = x;
  m_yCursor = y;
  CFRelease(event);
}

void OSXScreen::reconfigure(uint32_t activeSides)
{
  const static auto sidesText = sidesMaskToString(activeSides);
  LOG_DEBUG("active sides: %s (0x%02x)", sidesText.c_str(), activeSides);
  m_activeSides = activeSides;
}

uint32_t OSXScreen::activeSides()
{
  return m_activeSides;
}

void OSXScreen::warpCursor(int32_t x, int32_t y)
{
  if (m_eventTapRunLoop && CFRunLoopGetCurrent() != m_eventTapRunLoop) {
    CFRunLoopPerformBlock(m_eventTapRunLoop, kCFRunLoopDefaultMode, ^{
      warpCursor(x, y);
    });
    CFRunLoopWakeUp(m_eventTapRunLoop);
    return;
  }

  // move cursor without generating events
  CGPoint pos;
  pos.x = x;
  pos.y = y;
  CGWarpMouseCursorPosition(pos);

  // save new cursor position
  m_xCursor = x;
  m_yCursor = y;
  m_cursorPosValid = true;
}

void OSXScreen::fakeInputBegin()
{
  ++m_fakeInputCount;
}

void OSXScreen::fakeInputEnd()
{
  if (m_fakeInputCount > 0) {
    --m_fakeInputCount;
  }
}

int32_t OSXScreen::getJumpZoneSize() const
{
  return 1;
}

bool OSXScreen::isAnyMouseButtonDown(uint32_t &buttonID) const
{
  if (m_buttonState.test(0)) {
    buttonID = kButtonLeft;
    return true;
  }

  return (GetCurrentButtonState() != 0);
}

void OSXScreen::getCursorCenter(int32_t &x, int32_t &y) const
{
  x = m_xCenter;
  y = m_yCenter;
}

uint32_t OSXScreen::registerHotKey(KeyID key, KeyModifierMask mask)
{
  // get mac virtual key and modifier mask matching deskflow key and mask
  uint32_t macKey, macMask;
  if (!m_keyState->mapDeskflowHotKeyToMac(key, mask, macKey, macMask)) {
    LOG_DEBUG("could not map hotkey id=%04x mask=%04x", key, mask);
    return 0;
  }

  // choose hotkey id
  uint32_t id;
  if (!m_oldHotKeyIDs.empty()) {
    id = m_oldHotKeyIDs.back();
    m_oldHotKeyIDs.pop_back();
  } else {
    id = m_hotKeys.size() + 1;
  }

  // if this hot key has modifiers only then we'll handle it specially
  EventHotKeyRef ref = nullptr;
  bool okay;
  if (key == kKeyNone) {
    if (m_modifierHotKeys.count(mask) > 0) {
      // already registered
      okay = false;
    } else {
      m_modifierHotKeys[mask] = id;
      okay = true;
    }
  } else {
    EventHotKeyID hkid = {'SNRG', (uint32_t)id};
    OSStatus status = RegisterEventHotKey(macKey, macMask, hkid, GetApplicationEventTarget(), 0, &ref);
    okay = (status == noErr);
    m_hotKeyToIDMap[HotKeyItem(macKey, macMask)] = id;
  }

  if (!okay) {
    m_oldHotKeyIDs.push_back(id);
    m_hotKeyToIDMap.erase(HotKeyItem(macKey, macMask));
    LOG_WARN(
        "failed to register hotkey %s (id=%04x mask=%04x)", deskflow::KeyMap::formatKey(key, mask).c_str(), key, mask
    );
    return 0;
  }

  m_hotKeys.try_emplace(id, HotKeyItem(ref, macKey, macMask));

  LOG_DEBUG(
      "registered hotkey %s (id=%04x mask=%04x) as id=%d", deskflow::KeyMap::formatKey(key, mask).c_str(), key, mask, id
  );
  return id;
}

void OSXScreen::unregisterHotKey(uint32_t id)
{
  // look up hotkey
  HotKeyMap::iterator i = m_hotKeys.find(id);
  if (i == m_hotKeys.end()) {
    return;
  }

  // unregister with OS
  bool okay;
  if (i->second.getRef() != nullptr) {
    okay = (UnregisterEventHotKey(i->second.getRef()) == noErr);
  } else {
    okay = false;
    // XXX -- this is inefficient
    for (ModifierHotKeyMap::iterator j = m_modifierHotKeys.begin(); j != m_modifierHotKeys.end(); ++j) {
      if (j->second == id) {
        m_modifierHotKeys.erase(j);
        okay = true;
        break;
      }
    }
  }
  if (!okay) {
    LOG_WARN("failed to unregister hotkey id=%d", id);
  } else {
    LOG_DEBUG("unregistered hotkey id=%d", id);
  }

  // discard hot key from map and record old id for reuse
  m_hotKeyToIDMap.erase(i->second);
  m_hotKeys.erase(i);
  m_oldHotKeyIDs.push_back(id);
  if (m_activeModifierHotKey == id) {
    m_activeModifierHotKey = 0;
    m_activeModifierHotKeyMask = 0;
  }
}

void OSXScreen::constructMouseButtonEventMap()
{
  const CGEventType source[NumButtonIDs][3] = {
      {kCGEventLeftMouseUp, kCGEventLeftMouseDragged, kCGEventLeftMouseDown},
      {kCGEventRightMouseUp, kCGEventRightMouseDragged, kCGEventRightMouseDown},
      {kCGEventOtherMouseUp, kCGEventOtherMouseDragged, kCGEventOtherMouseDown},
      {kCGEventOtherMouseUp, kCGEventOtherMouseDragged, kCGEventOtherMouseDown},
      {kCGEventOtherMouseUp, kCGEventOtherMouseDragged, kCGEventOtherMouseDown},
      {kCGEventOtherMouseUp, kCGEventOtherMouseDragged, kCGEventOtherMouseDown}
  };

  for (uint16_t button = 0; button < NumButtonIDs; button++) {
    MouseButtonEventMapType new_map;
    for (uint16_t state = (uint32_t)kMouseButtonUp; state < kMouseButtonStateMax; state++) {
      CGEventType curEvent = source[button][state];
      new_map[state] = curEvent;
    }
    MouseButtonEventMap[button] = new_map;
  }
}

void OSXScreen::postMouseEvent(CGPoint &pos) const
{
  // check if cursor position is valid on the client display configuration
  // stkamp@users.sourceforge.net
  CGDisplayCount displayCount = 0;
  CGGetDisplaysWithPoint(pos, 0, nullptr, &displayCount);
  if (displayCount == 0) {
    // cursor position invalid - clamp to bounds of last valid display.
    // find the last valid display using the last cursor position.
    displayCount = 0;
    CGDirectDisplayID displayID;
    CGGetDisplaysWithPoint(CGPointMake(m_xCursor, m_yCursor), 1, &displayID, &displayCount);
    if (displayCount != 0) {
      CGRect displayRect = CGDisplayBounds(displayID);
      if (pos.x < displayRect.origin.x) {
        pos.x = displayRect.origin.x;
      } else if (pos.x > displayRect.origin.x + displayRect.size.width - 1) {
        pos.x = displayRect.origin.x + displayRect.size.width - 1;
      }
      if (pos.y < displayRect.origin.y) {
        pos.y = displayRect.origin.y;
      } else if (pos.y > displayRect.origin.y + displayRect.size.height - 1) {
        pos.y = displayRect.origin.y + displayRect.size.height - 1;
      }
    }
  }

  CGEventType type = kCGEventMouseMoved;

  int8_t button = m_buttonState.getFirstButtonDown();
  if (button != -1) {
    MouseButtonEventMapType thisButtonType = MouseButtonEventMap[button];
    type = thisButtonType[kMouseButtonDragged];
  }

  CGEventRef event = CGEventCreateMouseEvent(nullptr, type, pos, static_cast<CGMouseButton>(button));

  if (button != -1 && needsEventNumber()) {
    CGEventSetIntegerValueField(event, kCGMouseEventNumber, m_mouseEventNumber);
  }

  // Dragging events also need the click state
  CGEventSetIntegerValueField(event, kCGMouseEventClickState, m_clickState);

  // Fix for sticky keys
  CGEventFlags modifiers = m_keyState->getModifierStateAsOSXFlags();
  CGEventSetFlags(event, modifiers);

  // Set movement deltas to fix issues with certain 3D programs
  SInt64 deltaX = pos.x;
  deltaX -= m_xCursor;

  SInt64 deltaY = pos.y;
  deltaY -= m_yCursor;

  CGEventSetIntegerValueField(event, kCGMouseEventDeltaX, deltaX);
  CGEventSetIntegerValueField(event, kCGMouseEventDeltaY, deltaY);

  double deltaFX = deltaX;
  double deltaFY = deltaY;

  CGEventSetDoubleValueField(event, kCGMouseEventDeltaX, deltaFX);
  CGEventSetDoubleValueField(event, kCGMouseEventDeltaY, deltaFY);

  CGEventPost(kCGHIDEventTap, event);

  CFRelease(event);
}

void OSXScreen::fakeMouseButton(ButtonID id, bool press)
{
  // Buttons are indexed from one, but the button down array is indexed from zero
  uint32_t index = mapDeskflowButtonToMac(id) - kButtonLeft;
  if (index >= NumButtonIDs) {
    return;
  }

  CGPoint pos;
  if (!m_cursorPosValid) {
    int32_t x, y;
    getCursorPos(x, y);
  }
  pos.x = m_xCursor;
  pos.y = m_yCursor;

  // variable used to detect mouse coordinate differences between
  // old & new mouse clicks. Used in double click detection.
  int32_t xDiff = m_xCursor - m_lastSingleClickXCursor;
  int32_t yDiff = m_yCursor - m_lastSingleClickYCursor;
  double diff = sqrt(xDiff * xDiff + yDiff * yDiff);
  // max sqrt(x^2 + y^2) difference allowed to double click
  // since we don't have double click distance in NX APIs
  // we define our own defaults.
  const double maxDiff = sqrt(2) + 0.0001;

  double clickTime = [NSEvent doubleClickInterval];

  // As long as the click is within the time window and distance window
  // increase clickState (double click, triple click, etc)
  // This will allow for higher than triple click but the quartz documenation
  // does not specify that this should be limited to triple click
  if (press) {
    if ((Arch::time() - m_lastClickTime) <= clickTime && diff <= maxDiff) {
      m_clickState++;
    } else {
      m_clickState = 1;
    }

    m_lastClickTime = Arch::time();
  }

  if (m_clickState == 1) {
    m_lastSingleClickXCursor = m_xCursor;
    m_lastSingleClickYCursor = m_yCursor;
  }

  EMouseButtonState state = press ? kMouseButtonDown : kMouseButtonUp;

  LOG_VERBOSE("faking mouse button id: %d press: %s", index, press ? "pressed" : "released");

  MouseButtonEventMapType thisButtonMap = MouseButtonEventMap[index];
  CGEventType type = thisButtonMap[state];

  CGEventRef event = CGEventCreateMouseEvent(nullptr, type, pos, static_cast<CGMouseButton>(index));

  if (needsEventNumber()) {
    if (press) {
      if (m_mouseEventNumber == 0) {
        // For some unknown reason, the first click event number must be unique and greater (but in the same ballpark)
        // than the last event number used by the system.
        m_mouseEventNumber =
            CGEventSourceCounterForEventType(kCGEventSourceStateHIDSystemState, kCGEventLeftMouseDown) +
            CGEventSourceCounterForEventType(kCGEventSourceStateHIDSystemState, kCGEventRightMouseDown) +
            CGEventSourceCounterForEventType(kCGEventSourceStateHIDSystemState, kCGEventOtherMouseDown);
      }
      ++m_mouseEventNumber;
    }
    CGEventSetIntegerValueField(event, kCGMouseEventNumber, m_mouseEventNumber);
  }

  CGEventSetIntegerValueField(event, kCGMouseEventClickState, m_clickState);

  // Fix for sticky keys
  CGEventFlags modifiers = m_keyState->getModifierStateAsOSXFlags();
  CGEventSetFlags(event, modifiers);

  m_buttonState.set(index, state);
  CGEventPost(kCGHIDEventTap, event);

  CFRelease(event);
}

void OSXScreen::fakeMouseMove(int32_t x, int32_t y)
{
  // synthesize event
  CGPoint pos;
  pos.x = x;
  pos.y = y;
  postMouseEvent(pos);

  // save new cursor position
  m_xCursor = static_cast<int32_t>(pos.x);
  m_yCursor = static_cast<int32_t>(pos.y);
  m_cursorPosValid = true;
}

void OSXScreen::fakeMouseRelativeMove(int32_t dx, int32_t dy) const
{
  // OS X does not appear to have a fake relative mouse move function.
  // simulate it by getting the current mouse position and adding to
  // that.  this can yield the wrong answer but there's not much else
  // we can do.

  // get current position
  CGEventRef event = CGEventCreate(nullptr);
  CGPoint oldPos = CGEventGetLocation(event);
  CFRelease(event);

  // synthesize event
  CGPoint pos;
  m_xCursor = static_cast<int32_t>(oldPos.x);
  m_yCursor = static_cast<int32_t>(oldPos.y);
  pos.x = oldPos.x + dx;
  pos.y = oldPos.y + dy;
  postMouseEvent(pos);

  // we now assume we don't know the current cursor position
  m_cursorPosValid = false;
}

void OSXScreen::fakeMouseWheel(ScrollDelta delta) const
{
  if (delta.x != 0 || delta.y != 0) {
    // use server's acceleration with a little boost since other platforms
    // take one wheel step as a larger step than the mac does.
    delta = applyScrollModifier(
        {static_cast<int32_t>(3.0 * delta.x / s_scrollDelta), static_cast<int32_t>(3.0 * delta.y / s_scrollDelta)}
    );
    // create a scroll event, post it and release it.  not sure if kCGScrollEventUnitLine
    // is the right choice here over kCGScrollEventUnitPixel
    CGEventRef scrollEvent = CGEventCreateScrollWheelEvent(nullptr, kCGScrollEventUnitLine, 2, delta.y, delta.x);

    // Fix for sticky keys
    CGEventFlags modifiers = m_keyState->getModifierStateAsOSXFlags();
    CGEventSetFlags(scrollEvent, modifiers);

    CGEventPost(kCGHIDEventTap, scrollEvent);
    CFRelease(scrollEvent);
  }
}

void OSXScreen::showCursor()
{
  LOG_DEBUG("showing cursor");

  CFStringRef propertyString = CFStringCreateWithCString(nullptr, "SetsCursorInBackground", kCFStringEncodingMacRoman);

  CGSSetConnectionProperty(_CGSDefaultConnection(), _CGSDefaultConnection(), propertyString, kCFBooleanTrue);

  CFRelease(propertyString);

  CGError error = CGDisplayShowCursor(m_displayID);
  if (error != kCGErrorSuccess) {
    LOG_ERR("failed to show cursor, error=%d", error);
  }

  // appears to fix "mouse randomly not showing" bug
  CGAssociateMouseAndMouseCursorPosition(true);

  logCursorVisibility();

  m_cursorHidden = false;
}

void OSXScreen::hideCursor()
{
  LOG_DEBUG("hiding cursor");

  CFStringRef propertyString = CFStringCreateWithCString(nullptr, "SetsCursorInBackground", kCFStringEncodingMacRoman);

  CGSSetConnectionProperty(_CGSDefaultConnection(), _CGSDefaultConnection(), propertyString, kCFBooleanTrue);

  CFRelease(propertyString);

  CGError error = CGDisplayHideCursor(m_displayID);
  if (error != kCGErrorSuccess) {
    LOG_ERR("failed to hide cursor, error=%d", error);
  }

  // appears to fix "mouse randomly not hiding" bug
  CGAssociateMouseAndMouseCursorPosition(true);

  logCursorVisibility();

  m_cursorHidden = true;
}

void OSXScreen::reassertCursorCapture()
{
  // Only meaningful while the pointer is not on this screen: that is when the
  // cursor is hidden (and, on a primary, the mouse dissociated), and that is
  // exactly the state macOS resets when the screen locks, unlocks, or the
  // session switches. Applies to secondaries too: their constructor hides the
  // cursor and macOS can make it visible again across a lock/unlock.
  const bool cursorActuallyVisible = CGCursorIsVisible();
  LOG_DEBUG(
      "reassertCursorCapture: primary=%d onScreen=%d cursorHidden=%d cursorVisible=%d", m_isPrimary,
      static_cast<int>(m_isOnScreen), m_cursorHidden, cursorActuallyVisible
  );
  if (m_isOnScreen || !m_cursorHidden) {
    return;
  }

  LOG_DEBUG("session change while on another screen: re-asserting hidden/captured cursor");
  hideCursor();
  if (m_isPrimary) {
    // must follow hideCursor(), which re-associates (see leave())
    CGAssociateMouseAndMouseCursorPosition(false);
  }
}

void OSXScreen::enable()
{
  // watch the clipboard
  m_clipboardTimer = m_events->newTimer(1.0, nullptr);
  m_events->addHandler(EventTypes::Timer, m_clipboardTimer, [this](const auto &) { checkClipboards(); });

  m_axTimer = m_events->newTimer(1.0, nullptr);
  m_events->addHandler(EventTypes::Timer, m_axTimer, [this](const auto &) {
    checkAXPermissions();
    // keep the scroll-wheel scaling cache fresh so the event-tap thread never
    // reads CFPreferences synchronously (which can stall the tap).
    refreshScrollScaling();
    // shortly after a session lock/unlock, keep re-asserting the cursor
    // capture: macOS may restore its own cursor state after the notification.
    if (m_reassertCursorUntil > Arch::time()) {
      reassertCursorCapture();
    }
    // Safety net independent of notifications: while the pointer is on a
    // client the cursor must be invisible. If macOS made it visible again
    // (screen lock, unlock, or anything else), capture it once more.
    // CGCursorIsVisible is deprecated but the only way to query this; a false
    // positive merely re-hides an already hidden cursor.
    if (!m_isOnScreen && m_cursorHidden && CGCursorIsVisible()) {
      LOG_DEBUG("cursor visible while on a client; re-asserting capture");
      reassertCursorCapture();
    }
  });

  // populate the scroll-wheel scaling cache before any scroll event can arrive
  refreshScrollScaling();

  if (m_isPrimary) {
    // FIXME -- start watching jump zones
  } else {
    // FIXME -- prevent system from entering power save mode

    hideCursor();

    // warp the mouse to the cursor center
    fakeMouseMove(m_xCenter, m_yCenter);
  }

  // there may be a better way to do this, but we register an event handler even if we're
  // not on the primary display (acting as a client). This way, if a local event comes in
  // (either keyboard or mouse), we can make sure to show the cursor if we've hidden it.
  installEventTap();
}

void OSXScreen::installEventTap()
{
  // kCGEventTapOptionDefault = 0x00000000 (Missing in 10.4, so specified literally)
  //
  // kCGHeadInsertEventTap puts the new tap ahead of every tap already registered
  // at kCGHIDEventTap, so a tap created later observes events earlier. CoreGraphics
  // exposes no absolute priority: tap location plus creation time is the only lever.
  const CGEventTapCallBack callback = m_isPrimary ? handleCGInputEvent : handleCGInputEventSecondary;

  m_eventTapPort = CGEventTapCreate(
      kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, kCGEventMaskForAllEvents, callback, this
  );

  if (m_eventTapPort == nullptr) {
    LOG_ERR("failed to create quartz event tap");
    return;
  }

  m_eventTapRLSR = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, m_eventTapPort, 0);
  if (m_eventTapRLSR == nullptr) {
    LOG_ERR("failed to create a CFRunLoopSourceRef for the quartz event tap");
    CFRelease(m_eventTapPort);
    m_eventTapPort = nullptr;
    return;
  }

  // Run the event tap on a dedicated thread with its own CFRunLoop so it fires
  // independently of whatever event loop the calling thread runs (e.g. QCoreApplication).
  // Use a semaphore to ensure m_eventTapRunLoop is set before this returns.
  // Capture the source locally so a concurrent teardownEventTap() cannot swap it
  // out from under this thread while it is winding down.
  CFRunLoopSourceRef rlsr = m_eventTapRLSR;
  auto sem = dispatch_semaphore_create(0);
  m_eventTapThread = std::thread([this, sem, rlsr]() {
    CFRunLoopRef runLoop = CFRunLoopGetCurrent();
    m_eventTapRunLoop = runLoop;
    CFRunLoopAddSource(runLoop, rlsr, kCFRunLoopDefaultMode);
    dispatch_semaphore_signal(sem);
    CFRunLoopRun();
    CFRunLoopRemoveSource(runLoop, rlsr, kCFRunLoopDefaultMode);
    m_eventTapRunLoop = nullptr;
  });
  dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
  dispatch_release(sem);
}

void OSXScreen::teardownEventTap()
{
  // Stop the run loop first, then join. Joining guarantees the tap thread has
  // already removed the source from its run loop, so the release below cannot
  // race with a thread that is still executing.
  if (m_eventTapRunLoop != nullptr) {
    CFRunLoopStop(m_eventTapRunLoop);
  }
  if (m_eventTapThread.joinable()) {
    m_eventTapThread.join();
  }

  if (m_eventTapRLSR != nullptr) {
    CFRelease(m_eventTapRLSR);
    m_eventTapRLSR = nullptr;
  }

  if (m_eventTapPort != nullptr) {
    CGEventTapEnable(m_eventTapPort, false);
    CFMachPortInvalidate(m_eventTapPort);
    CFRelease(m_eventTapPort);
    m_eventTapPort = nullptr;
  }
}

void OSXScreen::rearmEventTap()
{
  // Only the primary screen owns the tap whose position in the HID chain matters.
  if (!m_isPrimary || m_eventTapRearming.exchange(true)) {
    return;
  }

  // Run off the event tap thread: teardownEventTap() joins that thread, and this
  // can be reached from inside the tap callback (onMouseMove -> switchScreen ->
  // leave()), so joining inline would deadlock.
  std::thread([this]() {
    teardownEventTap();
    installEventTap();
    m_eventTapRearming = false;
  }).detach();
}

void OSXScreen::disable()
{
  showCursor();

  // FIXME -- stop watching jump zones, stop capturing input

  teardownEventTap();

  // FIXME -- allow system to enter power saving mode

  if (m_clipboardTimer != nullptr) {
    m_events->removeHandler(EventTypes::Timer, m_clipboardTimer);
    m_events->deleteTimer(m_clipboardTimer);
    m_clipboardTimer = nullptr;
  }

  if (m_axTimer != nullptr) {
    m_events->removeHandler(EventTypes::Timer, m_axTimer);
    m_events->deleteTimer(m_axTimer);
    m_axTimer = nullptr;
  }

  m_isOnScreen = m_isPrimary;
}

void OSXScreen::enter()
{
  m_isOnScreen = true;
  showCursor();

  if (m_isPrimary) {
    // re-couple the mouse to the cursor, undoing the capture from leave()
    CGAssociateMouseAndMouseCursorPosition(true);
    setZeroSuppressionInterval();
  } else {
    // reset buttons
    m_buttonState.reset();

    // wakes the client screen
    io_registry_entry_t entry =
        IORegistryEntryFromPath(kIOMasterPortDefault, "IOService:/IOResources/IODisplayWrangler");

    if (entry != MACH_PORT_NULL) {
      IORegistryEntrySetCFProperty(entry, CFSTR("IORequestIdle"), kCFBooleanFalse);
      IOObjectRelease(entry);
    }

    avoidSupression();
  }
}

bool OSXScreen::canLeave()
{
  return true;
}

void OSXScreen::leave()
{
  hideCursor();

  if (m_isPrimary) {
    avoidHesitatingCursor();

    // capture the mouse: freeze the cursor so no local app sees motion while on
    // a client (onMouseMove reads raw deltas instead). must follow hideCursor(),
    // which re-associates. re-coupled in enter()/disable().
    CGAssociateMouseAndMouseCursorPosition(false);

    // Another process may have registered its own HID-level event tap after ours
    // (mouse-gesture utilities do exactly that). Head insertion means the newest
    // tap runs first, so such a tap can swallow events before we ever see them.
    // Re-registering here restores our position at the front of the chain for as
    // long as the cursor stays on a client, which is when suppression matters.
    rearmEventTap();
  }

  // now off screen
  m_isOnScreen = false;
}

bool OSXScreen::setClipboard(ClipboardID, const IClipboard *src)
{
  if (src != nullptr) {
    LOG_DEBUG("setting clipboard");
    Clipboard::copy(&m_pasteboard, src);
  }
  return true;
}

void OSXScreen::checkClipboards()
{
  LOG_VERBOSE("checking clipboard");
  if (m_pasteboard.synchronize()) {
    LOG_DEBUG("clipboard changed");
    sendClipboardEvent(EventTypes::ClipboardGrabbed, kClipboardClipboard);
    sendClipboardEvent(EventTypes::ClipboardGrabbed, kClipboardSelection);
  }
}

void OSXScreen::openScreensaver(bool notify)
{
  m_screensaverNotify = notify;
  if (!m_screensaverNotify) {
    m_screensaver->disable();
  }
}

void OSXScreen::closeScreensaver()
{
  if (!m_screensaverNotify) {
    m_screensaver->enable();
  }
}

void OSXScreen::screensaver(bool activate)
{
  if (activate) {
    m_screensaver->activate();
  } else {
    m_screensaver->deactivate();
  }
}

void OSXScreen::resetOptions()
{
  // no options
}

void OSXScreen::setOptions(const OptionsList &)
{
  // no options
}

void OSXScreen::setSequenceNumber(uint32_t seqNum)
{
  m_sequenceNumber = seqNum;
}

bool OSXScreen::isPrimary() const
{
  return m_isPrimary;
}

void OSXScreen::sendEvent(EventTypes type, void *data) const
{
  m_events->addEvent(Event(type, getEventTarget(), data));
}

void OSXScreen::sendClipboardEvent(EventTypes type, ClipboardID id) const
{
  ClipboardInfo *info = (ClipboardInfo *)malloc(sizeof(ClipboardInfo));
  info->m_id = id;
  info->m_sequenceNumber = m_sequenceNumber;
  sendEvent(type, info);
}

void OSXScreen::handleSystemEvent(const Event &event)
{
  EventRef *carbonEvent = static_cast<EventRef *>(event.getData());
  assert(carbonEvent != nullptr);

  uint32_t eventClass = GetEventClass(*carbonEvent);

  switch (eventClass) {
  case kEventClassMouse:
    switch (GetEventKind(*carbonEvent)) {
    case kDeskflowEventMouseScroll: {
      OSStatus r;
      long xScroll;
      long yScroll;

      // get scroll amount
      r = GetEventParameter(
          *carbonEvent, kDeskflowMouseScrollAxisX, typeSInt32, nullptr, sizeof(xScroll), nullptr, &xScroll
      );
      if (r != noErr) {
        xScroll = 0;
      }
      r = GetEventParameter(
          *carbonEvent, kDeskflowMouseScrollAxisY, typeSInt32, nullptr, sizeof(yScroll), nullptr, &yScroll
      );
      if (r != noErr) {
        yScroll = 0;
      }

      if (xScroll != 0 || yScroll != 0) {
        onMouseWheel(-mapScrollWheelToDeskflow(xScroll), mapScrollWheelToDeskflow(yScroll));
      }
    }
    }
    break;

  case kEventClassKeyboard:
    switch (GetEventKind(*carbonEvent)) {
    case kEventHotKeyPressed:
    case kEventHotKeyReleased:
      onHotKey(*carbonEvent);
      break;
    }

    break;

  case kEventClassWindow:
    // 2nd param was formerly GetWindowEventTarget(m_userInputWindow) which is 32-bit only,
    // however as m_userInputWindow is never initialized to anything we can take advantage of
    // the fact that GetWindowEventTarget(nullptr) == nullptr
    SendEventToEventTarget(*carbonEvent, nullptr);
    switch (GetEventKind(*carbonEvent)) {
    case kEventWindowActivated:
      LOG_VERBOSE("window activated");
      break;

    case kEventWindowDeactivated:
      LOG_VERBOSE("window deactivated");
      break;

    case kEventWindowFocusAcquired:
      LOG_VERBOSE("focus acquired");
      break;

    case kEventWindowFocusRelinquish:
      LOG_VERBOSE("focus released");
      break;
    }
    break;

  default:
    SendEventToEventTarget(*carbonEvent, GetEventDispatcherTarget());
    break;
  }
}

bool OSXScreen::onMouseMove(CGEventRef event)
{
  if (m_isOnScreen) {
    // motion on primary screen.  the event may have been queued a while, so
    // query the live cursor position rather than the stale event position.
    CGEventRef posEvent = CGEventCreate(NULL);
    CGPoint pos = CGEventGetLocation(posEvent);
    CFRelease(posEvent);
    CGFloat mx = pos.x;
    CGFloat my = pos.y;

    LOG_VERBOSE("mouse move %+f,%+f", mx, my);

    CGFloat x = mx - m_xCursor;
    CGFloat y = my - m_yCursor;

    if ((x == 0 && y == 0) || (mx == m_xCenter && mx == m_yCenter)) {
      return true;
    }

    m_xCursor = (int32_t)mx;
    m_yCursor = (int32_t)my;

    accumulateGesture((int32_t)x, (int32_t)y);

    sendEvent(EventTypes::PrimaryScreenMotionOnPrimary, MotionInfo::alloc(m_xCursor, m_yCursor));
  } else {
    // motion on secondary screen.  the cursor is frozen (see leave()), so read
    // raw deltas from the event instead of diffing position.
    int32_t dx = (int32_t)CGEventGetIntegerValueField(event, kCGMouseEventDeltaX);
    int32_t dy = (int32_t)CGEventGetIntegerValueField(event, kCGMouseEventDeltaY);

    LOG_VERBOSE("mouse delta %+d,%+d", dx, dy);

    accumulateGesture(dx, dy);

    if (dx != 0 || dy != 0) {
      sendEvent(EventTypes::PrimaryScreenMotionOnSecondary, MotionInfo::alloc(dx, dy));
    }
  }

  return true;
}

bool OSXScreen::onMouseButton(bool pressed, uint16_t macButton)
{
  // Buttons 2 and 3 are inverted on the mac
  ButtonID button = mapMacButtonToDeskflow(macButton);

  if (pressed) {
    LOG_VERBOSE("event: button press button=%d", button);

    if (beginGesture(button)) {
      // A gesture button was pressed. Hold the press back: the active screen
      // must not see it until we know whether the user is gesturing or merely
      // clicking, otherwise every gesture would also deliver a click.
      return true;
    }

    if (button != kButtonNone) {
      KeyModifierMask mask = m_keyState->getActiveModifiers();
      sendEvent(EventTypes::PrimaryScreenButtonDown, ButtonInfo::alloc(button, mask));
    }

    return false;
  }

  LOG_VERBOSE("event: button release button=%d", button);

  switch (finishGesture(button)) {
  case GestureOutcome::Fired:
  case GestureOutcome::Swallowed:
    // The drag was a gesture (or an unmatched stroke). The press was held
    // back, so neither a replayed click nor a lone release may reach the
    // active screen.
    return true;

  case GestureOutcome::Click:
    // The press was held back but the user only clicked, so deliver the click
    // that the active screen never saw.
    deliverHeldClick(button);
    return true;

  case GestureOutcome::None:
    break;
  }

  if (button != kButtonNone) {
    KeyModifierMask mask = m_keyState->getActiveModifiers();
    sendEvent(EventTypes::PrimaryScreenButtonUp, ButtonInfo::alloc(button, mask));
  }

  return false;
}

namespace
{
int32_t gestureAbs(int32_t value)
{
  return value < 0 ? -value : value;
}

//! Marks the synthetic clicks posted to replay a held-back press, so the event
//! tap can tell them apart from real input and let them through untouched.
constexpr int64_t kGestureReplayTag = 0x0D35F10A;

CGEventType gestureDownEvent(ButtonID button)
{
  switch (button) {
  case kButtonRight:
    return kCGEventRightMouseDown;

  case kButtonMiddle:
    return kCGEventOtherMouseDown;

  default:
    return kCGEventLeftMouseDown;
  }
}

CGEventType gestureUpEvent(ButtonID button)
{
  switch (button) {
  case kButtonRight:
    return kCGEventRightMouseUp;

  case kButtonMiddle:
    return kCGEventOtherMouseUp;

  default:
    return kCGEventLeftMouseUp;
  }
}

CGMouseButton gestureMacButton(ButtonID button)
{
  switch (button) {
  case kButtonRight:
    return kCGMouseButtonRight;

  case kButtonMiddle:
    return kCGMouseButtonCenter;

  default:
    return kCGMouseButtonLeft;
  }
}
} // namespace

bool OSXScreen::hasGestureOnButton(ButtonID button) const
{
  for (const auto &entry : m_gestures) {
    if (entry.second.m_button == button) {
      return true;
    }
  }
  return false;
}

uint32_t OSXScreen::registerGesture(ButtonID button, GestureDirection direction, GestureDirection direction2)
{
  if (button == kButtonNone) {
    return 0;
  }

  const uint32_t id = m_nextGestureId++;
  m_gestures[id] = {button, direction, direction2};

  if (direction2 != GestureDirection::None) {
    LOG_DEBUG("registered gesture button=%d direction=%d+%d as id=%u", button, static_cast<int>(direction),
              static_cast<int>(direction2), id);
  } else {
    LOG_DEBUG("registered gesture button=%d direction=%d as id=%u", button, static_cast<int>(direction), id);
  }
  return id;
}

void OSXScreen::unregisterGesture(uint32_t id)
{
  if (m_gestures.erase(id) == 0) {
    return;
  }

  LOG_DEBUG("unregistered gesture id=%u", id);

  // Do not keep tracking a button whose gestures are all gone.
  if (m_activeGestureButton != kButtonNone && !hasGestureOnButton(m_activeGestureButton)) {
    resetGesture();
  }
}

bool OSXScreen::beginGesture(ButtonID button)
{
  resetGesture();

  // Gestures are only recognized while the cursor is on this screen. Off-screen
  // the press is forwarded straight through, which leaves the active screen's
  // own gesture tool working; holding it back there would hand that tool motion
  // with no button held, so it could never recognize a gesture of its own.
  if (!m_isOnScreen || button == kButtonNone || !hasGestureOnButton(button)) {
    return false;
  }

  m_activeGestureButton = button;
  // Remember the state at press time so a replayed click carries the modifiers
  // that were held when the user actually pressed the button.
  m_gesturePressMask = m_keyState->getActiveModifiers();
  m_gesturePressFlags = m_keyState->getModifierStateAsOSXFlags();

  // Ask the GUI to draw the cursor trail so the user can see the stroke while
  // the gesture is being recognised.
  ipcSendToClient(QStringLiteral("gestureTrail"), QStringLiteral("start"));

  LOG_VERBOSE("gesture tracking started on button=%d", button);
  return true;
}

void OSXScreen::resetGesture()
{
  m_activeGestureButton = kButtonNone;
  m_gestureX = 0;
  m_gestureY = 0;
  m_gestureSeg1 = GestureDirection::None;
  m_gestureSeg2 = GestureDirection::None;
  m_gestureSegX = 0;
  m_gestureSegY = 0;
  m_gestureTurnPending = false;
  m_gestureScrollFired = false;
  m_scrollGestureAccumX = 0;
  m_scrollGestureAccumY = 0;
}

GestureDirection OSXScreen::gestureDirectionFromVector(int32_t x, int32_t y)
{
  if (x == 0 && y == 0) {
    return GestureDirection::None;
  }

  // Convert to mathematical orientation (y grows upward) and take the angle.
  const double angle = std::atan2(-(double)y, (double)x) * 180.0 / M_PI; // (-180, 180]

  // The 8 directions evenly divide the circle, so each occupies a 45-degree
  // sector centred on its own direction (right = 0°, up = 90°, ...).
  static constexpr GestureDirection kSectors[8] = {
      GestureDirection::Right,   GestureDirection::UpRight, GestureDirection::Up,     GestureDirection::UpLeft,
      GestureDirection::Left,    GestureDirection::DownLeft, GestureDirection::Down,  GestureDirection::DownRight
  };
  int sector = static_cast<int>(std::floor((angle + 22.5) / 45.0));
  sector = ((sector % 8) + 8) % 8;
  return kSectors[sector];
}

void OSXScreen::gestureDirectionAxis(GestureDirection direction, double &ux, double &uy)
{
  // Screen coordinates: x grows right, y grows down.
  ux = 0;
  uy = 0;
  switch (direction) {
  case GestureDirection::Right: ux = 1; break;
  case GestureDirection::Left: ux = -1; break;
  case GestureDirection::Up: uy = -1; break;
  case GestureDirection::Down: uy = 1; break;
  case GestureDirection::UpRight: ux = 1; uy = -1; break;
  case GestureDirection::UpLeft: ux = -1; uy = -1; break;
  case GestureDirection::DownLeft: ux = -1; uy = 1; break;
  case GestureDirection::DownRight: ux = 1; uy = 1; break;
  default: break;
  }
  if (ux != 0 && uy != 0) {
    const double inv = 1.0 / std::sqrt(2.0);
    ux *= inv;
    uy *= inv;
  }
}

void OSXScreen::accumulateGesture(int32_t dx, int32_t dy)
{
  if (m_activeGestureButton == kButtonNone) {
    return;
  }

  m_gestureX += dx;
  m_gestureY += dy;

  // Segment 1: classify the stroke once it leaves the press point by more than
  // the threshold. The press point is the origin of this segment.
  if (m_gestureSeg1 == GestureDirection::None) {
    if (m_gestureX * m_gestureX + m_gestureY * m_gestureY >= kGestureThreshold * kGestureThreshold) {
      m_gestureSeg1 = gestureDirectionFromVector(m_gestureX, m_gestureY);
      m_gestureSegX = 0;
      m_gestureSegY = 0;
      LOG_VERBOSE("gesture segment 1 locked direction=%d after dragging %+d,%+d", static_cast<int>(m_gestureSeg1),
                  m_gestureX, m_gestureY);
    }
    return;
  }

  // Segment 2 already locked: a stroke only has two segments, ignore the rest.
  if (m_gestureSeg2 != GestureDirection::None) {
    return;
  }

  m_gestureSegX += dx;
  m_gestureSegY += dy;

  // A turn was detected earlier; its point is the origin of segment 2, so wait
  // until the movement from there is long enough to classify the segment.
  if (m_gestureTurnPending) {
    if (m_gestureSegX * m_gestureSegX + m_gestureSegY * m_gestureSegY >= kGestureThreshold * kGestureThreshold) {
      const GestureDirection direction = gestureDirectionFromVector(m_gestureSegX, m_gestureSegY);
      m_gestureTurnPending = false;
      m_gestureSegX = 0;
      m_gestureSegY = 0;
      if (direction != GestureDirection::None && direction != m_gestureSeg1) {
        m_gestureSeg2 = direction;
        LOG_VERBOSE("gesture segment 2 locked direction=%d", static_cast<int>(m_gestureSeg2));
      }
    }
    return;
  }

  // Detect the turn away from segment 1. The corner (the end of segment 1 and
  // the origin of segment 2) is where the stroke deviates from segment 1's
  // axis by more than the threshold, either sideways or as a full reversal.
  double ux = 0;
  double uy = 0;
  gestureDirectionAxis(m_gestureSeg1, ux, uy);
  const double parallel = m_gestureSegX * ux + m_gestureSegY * uy;
  const double lengthSq = (double)m_gestureSegX * m_gestureSegX + (double)m_gestureSegY * m_gestureSegY;
  const double perpSq = lengthSq - parallel * parallel;
  const double threshold = (double)kGestureThreshold;

  if (perpSq >= threshold * threshold || parallel <= -threshold) {
    LOG_VERBOSE("gesture turn detected after %+d,%+d", m_gestureSegX, m_gestureSegY);
    m_gestureTurnPending = true;
    m_gestureSegX = 0;
    m_gestureSegY = 0;
  } else if (lengthSq >= threshold * threshold) {
    // Still moving along segment 1: slide the corner forward so any later turn
    // is measured against recent movement only.
    m_gestureSegX = 0;
    m_gestureSegY = 0;
  }
}

OSXScreen::GestureOutcome OSXScreen::finishGesture(ButtonID button)
{
  if (button == kButtonNone || button != m_activeGestureButton) {
    return GestureOutcome::None;
  }

  const bool scrollFired = m_gestureScrollFired;
  const GestureDirection seg1 = m_gestureSeg1;
  const GestureDirection seg2 = m_gestureSeg2;
  const ButtonID gestureButton = m_activeGestureButton;

  resetGesture();

  // The stroke is over either way, so the GUI can remove the cursor trail.
  ipcSendToClient(QStringLiteral("gestureTrail"), QStringLiteral("stop"));

  if (scrollFired) {
    // Wheel movements already ran a gesture for this press, so the press is not
    // a click and must not be replayed.
    return GestureOutcome::Fired;
  }

  // A two-segment stroke is a gesture of its own: it fires a two-segment
  // binding when one matches, but it must not fall back to the first segment's
  // single-segment binding — an L like downright then downleft is not a plain
  // downright. Single-segment bindings only apply to straight strokes.
  if (seg2 != GestureDirection::None) {
    if (const uint32_t id = findGesture(gestureButton, seg1, seg2); id != 0) {
      LOG_DEBUG("gesture recognised button=%d direction=%d+%d", gestureButton, static_cast<int>(seg1),
                static_cast<int>(seg2));
      fireGesture(id);
      ipcSendToClient(QStringLiteral("gestureMatched"), gestureBindingText(id));
      return GestureOutcome::Fired;
    }
    LOG_DEBUG("no two-segment binding for button=%d direction=%d+%d; swallowing the stroke", gestureButton,
              static_cast<int>(seg1), static_cast<int>(seg2));
    return GestureOutcome::Swallowed;
  }

  if (seg1 != GestureDirection::None) {
    if (const uint32_t id = findGesture(gestureButton, seg1); id != 0) {
      LOG_DEBUG("gesture recognised button=%d direction=%d", gestureButton, static_cast<int>(seg1));
      fireGesture(id);
      ipcSendToClient(QStringLiteral("gestureMatched"), gestureBindingText(id));
      return GestureOutcome::Fired;
    }

    // The stroke left the press point but matches no binding: it is a gesture
    // attempt, so deliver nothing — neither an action nor a click replay.
    LOG_VERBOSE("no gesture bound to button=%d segment1=%d; swallowing the stroke", gestureButton,
                static_cast<int>(seg1));
    return GestureOutcome::Swallowed;
  }

  // The pointer never moved past the gesture threshold: it was a plain click.
  return GestureOutcome::Click;
}

void OSXScreen::fireGesture(uint32_t id)
{
  // A gesture is instantaneous, so it is delivered as a hot key press followed
  // immediately by the matching release. The release is not optional: it runs
  // the actions bound to the hot key's release, and it is what lifts the keys a
  // keystroke() action pressed. Without it those keys stay down on the active
  // screen after a single gesture.
  m_events->addEvent(Event(EventTypes::PrimaryScreenHotkeyDown, getEventTarget(), HotKeyInfo::alloc(id)));
  m_events->addEvent(Event(EventTypes::PrimaryScreenHotkeyUp, getEventTarget(), HotKeyInfo::alloc(id)));
}

uint32_t OSXScreen::findGesture(ButtonID button, GestureDirection direction, GestureDirection direction2) const
{
  for (const auto &[id, binding] : m_gestures) {
    if (binding.m_button == button && binding.m_direction == direction && binding.m_direction2 == direction2) {
      return id;
    }
  }
  return 0;
}

QString OSXScreen::gestureBindingText(uint32_t id) const
{
  static const char *s_buttonNames[] = {"none", "left", "middle", "right"};

  static const char *s_directionNames[] = {
      "left",     "right",     "up",         "down",       "upleft",
      "upright",  "downleft",  "downright",  "scrollup",   "scrolldown",
      "scrollleft", "scrollright", "none",
  };

  const auto it = m_gestures.find(id);
  if (it == m_gestures.end()) {
    return {};
  }
  const auto &binding = it->second;

  QString direction = s_directionNames[static_cast<int>(binding.m_direction)];
  if (binding.m_direction2 != GestureDirection::None) {
    direction += QStringLiteral("+") + s_directionNames[static_cast<int>(binding.m_direction2)];
  }

  return QStringLiteral("gesture(%1,%2)").arg(s_buttonNames[static_cast<int>(binding.m_button)], direction);
}

bool OSXScreen::handleGestureScroll(int32_t xDelta, int32_t yDelta)
{
  if (m_activeGestureButton == kButtonNone || (xDelta == 0 && yDelta == 0)) {
    return false;
  }

  bool fired = false;
  bool consumed = false;

  // Scroll gestures accumulate: while the gesture button is held, wheel deltas
  // pile up per axis and each time the accumulated amount crosses the
  // threshold the bound action fires. The remainder carries over, so simply
  // keeping the wheel rolling fires the action again and again until the
  // button is released.
  const auto processAxis = [&](int32_t delta, GestureDirection positive, GestureDirection negative, int32_t &accum) {
    if (delta == 0) {
      return;
    }

    accum += delta;
    const GestureDirection direction = (accum > 0) ? positive : negative;
    const uint32_t id = findGesture(m_activeGestureButton, direction);
    if (id == 0) {
      // Nothing bound to this direction: do not accumulate and let the wheel
      // movement through to the active screen.
      accum -= delta;
      return;
    }

    consumed = true;
    if (gestureAbs(accum) >= kScrollGestureThreshold) {
      LOG_DEBUG("scroll gesture recognised button=%d direction=%d", m_activeGestureButton, static_cast<int>(direction));
      fireGesture(id);
      ipcSendToClient(QStringLiteral("gestureMatched"), gestureBindingText(id));
      accum -= (accum > 0) ? kScrollGestureThreshold : -kScrollGestureThreshold;
      fired = true;
    }
  };

  processAxis(yDelta, GestureDirection::ScrollUp, GestureDirection::ScrollDown, m_scrollGestureAccumY);
  processAxis(xDelta, GestureDirection::ScrollRight, GestureDirection::ScrollLeft, m_scrollGestureAccumX);

  if (fired) {
    // The press belonged to a scroll gesture, so do not replay it as a click.
    m_gestureScrollFired = true;
  }

  return consumed;
}

void OSXScreen::deliverHeldClick(ButtonID button)
{
  if (button == kButtonNone) {
    return;
  }

  if (!m_isOnScreen) {
    // The active screen is a client. Hand it the press and the release back to
    // back, which is what it would have received without gesture handling.
    sendEvent(EventTypes::PrimaryScreenButtonDown, ButtonInfo::alloc(button, m_gesturePressMask));
    sendEvent(EventTypes::PrimaryScreenButtonUp, ButtonInfo::alloc(button, m_gesturePressMask));
    return;
  }

  // The cursor is on this screen, so the local application never saw the press.
  // Post the whole click as synthetic input; the tap recognises the tag and lets
  // these events through untouched.
  CGEventRef posEvent = CGEventCreate(nullptr);
  const CGPoint pos = CGEventGetLocation(posEvent);
  CFRelease(posEvent);

  const CGEventType types[] = {gestureDownEvent(button), gestureUpEvent(button)};
  for (CGEventType type : types) {
    CGEventRef click = CGEventCreateMouseEvent(nullptr, type, pos, gestureMacButton(button));
    if (click == nullptr) {
      continue;
    }

    CGEventSetIntegerValueField(click, kCGEventSourceUserData, kGestureReplayTag);
    CGEventSetFlags(click, m_gesturePressFlags);
    CGEventPost(kCGHIDEventTap, click);
    CFRelease(click);
  }

  LOG_VERBOSE("replayed held click for button=%d", button);
}

bool OSXScreen::onMouseWheel(int32_t xDelta, int32_t yDelta)
{
  LOG_VERBOSE("event: button wheel delta=%+d,%+d", xDelta, yDelta);

  if (handleGestureScroll(xDelta, yDelta)) {
    // The wheel movement completed a gesture, so the active screen must not
    // also scroll.
    return true;
  }

  sendEvent(EventTypes::PrimaryScreenWheel, WheelInfo::alloc(xDelta, yDelta));
  return false;
}

void OSXScreen::displayReconfigurationCallback(
    CGDirectDisplayID displayID, CGDisplayChangeSummaryFlags flags, void *inUserData
)
{
  OSXScreen *screen = (OSXScreen *)inUserData;

  // Closing or opening the lid when an external monitor is
  // connected causes an kCGDisplayBeginConfigurationFlag event
  CGDisplayChangeSummaryFlags mask = kCGDisplayBeginConfigurationFlag | kCGDisplayMovedFlag | kCGDisplaySetModeFlag |
                                     kCGDisplayAddFlag | kCGDisplayRemoveFlag | kCGDisplayEnabledFlag |
                                     kCGDisplayDisabledFlag | kCGDisplayMirrorFlag | kCGDisplayUnMirrorFlag |
                                     kCGDisplayDesktopShapeChangedFlag;

  LOG_VERBOSE("event: display was reconfigured: %x %x %x", flags, mask, flags & mask);

  if (flags & mask) { /* Something actually did change */
    LOG_VERBOSE("event: screen changed shape; refreshing dimensions");
    if (!screen->updateScreenShape(displayID, flags)) {
      LOG_ERR("failed to update screen shape during display reconfiguration");
    }
  }
}

bool OSXScreen::onKey(CGEventRef event)
{
  CGEventType eventKind = CGEventGetType(event);

  // get the key and active modifiers
  uint32_t virtualKey = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
  CGEventFlags macMask = CGEventGetFlags(event);
  LOG_VERBOSE("event: Key event kind: %d, keycode=%d", eventKind, virtualKey);

  // Special handling to track state of modifiers
  if (eventKind == kCGEventFlagsChanged) {
    // get old and new modifier state
    KeyModifierMask oldMask = getActiveModifiers();
    KeyModifierMask newMask = m_keyState->mapModifiersFromOSX(macMask);
    m_keyState->handleModifierKeys(getEventTarget(), oldMask, newMask);

    // if the current set of modifiers exactly matches a modifiers-only
    // hot key then generate a hot key down event. Like the key-based hotkeys
    // below, modifiers-only hotkeys only intercept local typing.
    if (m_activeModifierHotKey == 0 && m_isOnScreen) {
      if (m_modifierHotKeys.count(newMask) > 0) {
        m_activeModifierHotKey = m_modifierHotKeys[newMask];
        m_activeModifierHotKeyMask = newMask;
        m_events->addEvent(
            Event(EventTypes::PrimaryScreenHotkeyDown, getEventTarget(), HotKeyInfo::alloc(m_activeModifierHotKey))
        );
      }
    }

    // if a modifiers-only hot key is active and should no longer be
    // then generate a hot key up event.
    else if (m_activeModifierHotKey != 0) {
      KeyModifierMask mask = (newMask & m_activeModifierHotKeyMask);
      if (mask != m_activeModifierHotKeyMask) {
        m_events->addEvent(
            Event(EventTypes::PrimaryScreenHotkeyUp, getEventTarget(), HotKeyInfo::alloc(m_activeModifierHotKey))
        );
        m_activeModifierHotKey = 0;
        m_activeModifierHotKeyMask = 0;
      }
    }

    return true;
  }

  // check for hot key
  HotKeyToIDMap::const_iterator i =
      m_hotKeyToIDMap.find(HotKeyItem(virtualKey, m_keyState->mapModifiersToCarbon(macMask) & 0xff00u));
  if (i != m_hotKeyToIDMap.end() && m_isOnScreen) {
    // Hotkeys only intercept typing on this screen: while the keys are being
    // forwarded to a client they must reach it untouched, otherwise common
    // combos like Ctrl+C could never copy on the client. Off-screen the code
    // below forwards the key normally instead of firing the hotkey.
    uint32_t id = i->second;

    // determine event type
    EventTypes type;
    if (eventKind == kCGEventKeyDown) {
      type = EventTypes::PrimaryScreenHotkeyDown;
    } else if (eventKind == kCGEventKeyUp) {
      type = EventTypes::PrimaryScreenHotkeyUp;
    } else {
      return false;
    }

    m_events->addEvent(Event(type, getEventTarget(), HotKeyInfo::alloc(id)));

    return true;
  }

  // decode event type
  bool down = (eventKind == kCGEventKeyDown);
  bool up = (eventKind == kCGEventKeyUp);
  bool isRepeat = (CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat) == 1);

  // map event to keys
  KeyModifierMask mask;
  OSXKeyState::KeyIDs keys;
  KeyButton button = m_keyState->mapKeyFromEvent(keys, &mask, event);
  if (button == 0) {
    return false;
  }

  // check for AltGr in mask.  if set we send neither the AltGr nor
  // the super modifiers to clients then remove AltGr before passing
  // the modifiers to onKey.
  KeyModifierMask sendMask = (mask & ~KeyModifierAltGr);
  if ((mask & KeyModifierAltGr) != 0) {
    sendMask &= ~KeyModifierSuper;
  }
  mask &= ~KeyModifierAltGr;

  // update button state
  if (down) {
    m_keyState->onKey(button, true, mask);
  } else if (up) {
    if (!m_keyState->isKeyDown(button)) {
      // up event for a dead key.  throw it away.
      return false;
    }
    m_keyState->onKey(button, false, mask);
  }

  // send key events
  for (OSXKeyState::KeyIDs::const_iterator i = keys.begin(); i != keys.end(); ++i) {
    m_keyState->sendKeyEvent(getEventTarget(), down, isRepeat, *i, sendMask, 1, button);
  }

  return true;
}

void OSXScreen::onMediaKey(CGEventRef event)
{
  KeyID keyID;
  bool down;
  bool isRepeat;

  if (!getMediaKeyEventInfo(event, &keyID, &down, &isRepeat)) {
    LOG_ERR("Failed to decode media key event");
    return;
  }

  LOG_VERBOSE("Media key event: keyID=0x%02x, %s, repeat=%s", keyID, (down ? "down" : "up"), (isRepeat ? "yes" : "no"));

  KeyButton button = 0;
  KeyModifierMask mask = m_keyState->getActiveModifiers();
  m_keyState->sendKeyEvent(getEventTarget(), down, isRepeat, keyID, mask, 1, button);
}

bool OSXScreen::onHotKey(EventRef event) const
{
  // get the hotkey id
  EventHotKeyID hkid;
  GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, nullptr, sizeof(EventHotKeyID), nullptr, &hkid);
  uint32_t id = hkid.id;

  // determine event type
  EventTypes type;
  uint32_t eventKind = GetEventKind(event);
  if (eventKind == kEventHotKeyPressed) {
    // Same rule as the tap path: hotkeys only intercept local typing, so a
    // key press while the cursor is on a client is forwarded untouched.
    if (!m_isOnScreen) {
      return false;
    }
    type = EventTypes::PrimaryScreenHotkeyDown;
  } else if (eventKind == kEventHotKeyReleased) {
    type = EventTypes::PrimaryScreenHotkeyUp;
  } else {
    return false;
  }

  m_events->addEvent(Event(type, getEventTarget(), HotKeyInfo::alloc(id)));

  return true;
}

ButtonID OSXScreen::mapDeskflowButtonToMac(uint16_t button) const
{
  switch (button) {
  case 1:
    return kButtonLeft;
  case 2:
    return kMacButtonMiddle;
  case 3:
    return kMacButtonRight;
  case 4:
    return kButtonExtra0;
  case 5:
    return kButtonExtra1;
  default:
    return kButtonNone;
  }
}

ButtonID OSXScreen::mapMacButtonToDeskflow(uint16_t macButton) const
{
  switch (macButton) {
  case 1:
    return kButtonLeft;
  case 2:
    return kButtonRight;
  case 3:
    return kButtonMiddle;
  case 4:
    return kButtonExtra0;
  case 5:
    return kButtonExtra1;
  default:
    return kButtonNone;
  }
}

int32_t OSXScreen::mapScrollWheelToDeskflow(int32_t x) const
{
  // return accelerated scrolling
  double d = (1.0 + getScrollSpeed()) * x;
  return static_cast<int32_t>(120.0 * d);
}

double OSXScreen::getScrollSpeed() const
{
  // mapScrollWheelToDeskflow() (and thus getScrollSpeed()) runs on the
  // CGEventTap thread for every scroll event. Reading CFPreferences
  // synchronously there can stall the tap and trip kCGEventTapDisabledByTimeout
  // (which leaks events to local apps). Return the cache instead; it is
  // populated off the tap thread by refreshScrollScaling().
  return m_scrollScaling.load(std::memory_order_relaxed);
}

void OSXScreen::refreshScrollScaling()
{
  double scaling = 0.0;

  CFPropertyListRef pref = ::CFPreferencesCopyValue(
      CFSTR("com.apple.scrollwheel.scaling"), kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
      kCFPreferencesAnyHost
  );
  if (pref != nullptr) {
    CFTypeID id = CFGetTypeID(pref);
    if (id == CFNumberGetTypeID()) {
      CFNumberRef value = static_cast<CFNumberRef>(pref);
      if (CFNumberGetValue(value, kCFNumberDoubleType, &scaling)) {
        if (scaling < 0.0) {
          scaling = 0.0;
        }
      }
    }
    CFRelease(pref);
  }

  m_scrollScaling.store(scaling, std::memory_order_relaxed);
}

void OSXScreen::updateButtons()
{
  uint32_t buttons = GetCurrentButtonState();

  m_buttonState.overwrite(buttons);
}

IKeyState *OSXScreen::getKeyState() const
{
  return m_keyState;
}

bool OSXScreen::updateScreenShape(const CGDirectDisplayID, const CGDisplayChangeSummaryFlags flags)
{
  return updateScreenShape();
}

bool OSXScreen::updateScreenShape()
{
  // get info for each display
  CGDisplayCount displayCount = 0;

  if (CGGetActiveDisplayList(0, nullptr, &displayCount) != CGDisplayNoErr) {
    return false;
  }

  if (displayCount == 0) {
    return false;
  }

  CGDirectDisplayID *displays = new CGDirectDisplayID[displayCount];
  if (displays == nullptr) {
    return false;
  }

  if (CGGetActiveDisplayList(displayCount, displays, &displayCount) != CGDisplayNoErr) {
    delete[] displays;
    return false;
  }

  // get smallest rect enclosing all display rects
  CGRect totalBounds = CGRectZero;
  for (CGDisplayCount i = 0; i < displayCount; ++i) {
    CGRect bounds = CGDisplayBounds(displays[i]);
    totalBounds = CGRectUnion(totalBounds, bounds);
  }

  // get shape of default screen
  m_x = (int32_t)totalBounds.origin.x;
  m_y = (int32_t)totalBounds.origin.y;
  m_w = (int32_t)totalBounds.size.width;
  m_h = (int32_t)totalBounds.size.height;

  // get center of default screen
  CGDirectDisplayID main = CGMainDisplayID();
  const CGRect rect = CGDisplayBounds(main);
  m_xCenter = (rect.origin.x + rect.size.width) / 2;
  m_yCenter = (rect.origin.y + rect.size.height) / 2;

  delete[] displays;
  // We want to notify the peer screen whether we are primary screen or not
  sendEvent(EventTypes::ScreenShapeChanged);

  LOG_DEBUG(
      "screen shape: center=%d,%d size=%dx%d on %u %s", m_x, m_y, m_w, m_h, displayCount,
      (displayCount == 1) ? "display" : "displays"
  );

  return true;
}

#pragma mark -

//
// FAST USER SWITCH NOTIFICATION SUPPORT
//
// OSXScreen::userSwitchCallback(void*)
//
// gets called if a fast user switch occurs
//

pascal OSStatus OSXScreen::userSwitchCallback(EventHandlerCallRef nextHandler, EventRef theEvent, void *inUserData)
{
  OSXScreen *screen = (OSXScreen *)inUserData;
  uint32_t kind = GetEventKind(theEvent);
  IEventQueue *events = screen->getEvents();

  if (kind == kEventSystemUserSessionDeactivated) {
    LOG_DEBUG("user session deactivated");
    events->addEvent(Event(EventTypes::ScreenSuspend, screen->getEventTarget()));
  } else if (kind == kEventSystemUserSessionActivated) {
    LOG_DEBUG("user session activated");
    events->addEvent(Event(EventTypes::ScreenResume, screen->getEventTarget()));
  }
  return (CallNextEventHandler(nextHandler, theEvent));
}

#pragma mark -

//
// SLEEP/WAKEUP NOTIFICATION SUPPORT
//
// OSXScreen::watchSystemPowerThread(void*)
//
// main of thread monitoring system power (sleep/wakup) using a CFRunLoop
//

void OSXScreen::watchSystemPowerThread(const void *)
{
  io_object_t notifier;
  IONotificationPortRef notificationPortRef;
  CFRunLoopSourceRef runloopSourceRef = 0;

  m_pmRunloop = CFRunLoopGetCurrent();
  // install system power change callback
  m_pmRootPort = IORegisterForSystemPower(this, &notificationPortRef, powerChangeCallback, &notifier);
  if (m_pmRootPort == 0) {
    LOG_WARN("IORegisterForSystemPower failed");
  } else {
    runloopSourceRef = IONotificationPortGetRunLoopSource(notificationPortRef);
    CFRunLoopAddSource(m_pmRunloop, runloopSourceRef, kCFRunLoopCommonModes);
  }

  // thread is ready
  {
    Lock lock(m_pmMutex);
    *m_pmThreadReady = true;
    m_pmThreadReady->signal();
  }

  // if we were unable to initialize then exit.  we must do this after
  // setting m_pmThreadReady to true otherwise the parent thread will
  // block waiting for it.
  if (m_pmRootPort == 0) {
    LOG_WARN("failed to init watchSystemPowerThread");
    return;
  }

  LOG_DEBUG("started watchSystemPowerThread");

  LOG_DEBUG("waiting for event loop");
  m_events->waitForReady();

  {
    Lock lockCarbon(m_carbonLoopMutex);
    if (*m_carbonLoopReady == false) {

      // we signalling carbon loop ready before starting
      // unless we know how to do it within the loop
      LOG_DEBUG("signalling carbon loop ready");

      *m_carbonLoopReady = true;
      m_carbonLoopReady->signal();
    }
  }

  // start the run loop
  LOG_DEBUG("starting carbon loop");
  CFRunLoopRun();
  LOG_DEBUG("carbon loop has stopped");

  // cleanup
  if (notificationPortRef) {
    CFRunLoopRemoveSource(m_pmRunloop, runloopSourceRef, kCFRunLoopDefaultMode);
    CFRunLoopSourceInvalidate(runloopSourceRef);
    CFRelease(runloopSourceRef);
  }

  Lock lock(m_pmMutex);
  IODeregisterForSystemPower(&notifier);
  m_pmRootPort = 0;
  LOG_DEBUG("stopped watchSystemPowerThread");
}

void OSXScreen::powerChangeCallback(void *refcon, io_service_t service, natural_t messageType, void *messageArg)
{
  ((OSXScreen *)refcon)->handlePowerChangeRequest(messageType, messageArg);
}

void OSXScreen::handlePowerChangeRequest(natural_t messageType, void *messageArg)
{
  // we've received a power change notification
  switch (messageType) {
  case kIOMessageSystemWillSleep:
    // OSXScreen has to handle this in the main thread so we have to
    // queue a confirm sleep event here.  we actually don't allow the
    // system to sleep until the event is handled.
    m_events->addEvent(
        Event(EventTypes::OsxScreenConfirmSleep, getEventTarget(), messageArg, Event::EventFlags::DontFreeData)
    );
    return;

  case kIOMessageSystemHasPoweredOn:
    LOG_DEBUG("system wakeup");
    m_events->addEvent(Event(EventTypes::ScreenResume, getEventTarget()));
    break;

  default:
    break;
  }

  Lock lock(m_pmMutex);
  if (m_pmRootPort != 0) {
    IOAllowPowerChange(m_pmRootPort, (long)messageArg);
  }
}

void OSXScreen::handleConfirmSleep(const Event &event)
{
  long messageArg = (long)event.getData();
  if (messageArg != 0) {
    Lock lock(m_pmMutex);
    if (m_pmRootPort != 0) {
      // deliver suspend event immediately.
      m_events->addEvent(
          Event(EventTypes::ScreenSuspend, getEventTarget(), nullptr, Event::EventFlags::DeliverImmediately)
      );

      LOG_DEBUG("system will sleep");
      IOAllowPowerChange(m_pmRootPort, messageArg);
    }
  }
}

bool OSXScreen::checkAXPermissions()
{
  if (AXIsProcessTrusted()) {
    return true;
  }
  LOG_CRIT("process is not trusted anymore, quitting");
  disable();
  App &app = App::instance();
  app.getEvents()->addEvent(Event(EventTypes::Quit, nullptr, new ExitEventData(s_exitFailed)));
  return false;
}

#pragma mark -

//
// GLOBAL HOTKEY OPERATING MODE SUPPORT (10.3)
//
// CoreGraphics private API (OSX 10.3)
// Source: http://ichiro.nnip.org/osx/Cocoa/GlobalHotkey.html
//
// We load the functions dynamically because they're not available in
// older SDKs.  We don't use weak linking because we want users of
// older SDKs to build an app that works on newer systems and older
// SDKs will not provide the symbols.
//
// FIXME: This is hosed as of OS 10.5; patches to repair this are
// a good thing.
//
#if 0

#ifdef __cplusplus
extern "C" {
#endif

typedef int CGSConnection;
typedef enum {
  CGSGlobalHotKeyEnable = 0,
  CGSGlobalHotKeyDisable = 1,
} CGSGlobalHotKeyOperatingMode;

extern CGSConnection _CGSDefaultConnection(void) WEAK_IMPORT_ATTRIBUTE;
extern CGError CGSGetGlobalHotKeyOperatingMode(CGSConnection connection, CGSGlobalHotKeyOperatingMode *mode) WEAK_IMPORT_ATTRIBUTE;
extern CGError CGSSetGlobalHotKeyOperatingMode(CGSConnection connection, CGSGlobalHotKeyOperatingMode mode) WEAK_IMPORT_ATTRIBUTE;

typedef CGSConnection (*_CGSDefaultConnection_t)(void);
typedef CGError (*CGSGetGlobalHotKeyOperatingMode_t)(CGSConnection connection, CGSGlobalHotKeyOperatingMode *mode);
typedef CGError (*CGSSetGlobalHotKeyOperatingMode_t)(CGSConnection connection, CGSGlobalHotKeyOperatingMode mode);

static _CGSDefaultConnection_t				s__CGSDefaultConnection;
static CGSGetGlobalHotKeyOperatingMode_t	s_CGSGetGlobalHotKeyOperatingMode;
static CGSSetGlobalHotKeyOperatingMode_t	s_CGSSetGlobalHotKeyOperatingMode;

#ifdef __cplusplus
}
#endif

#define LOOKUP(name_)                                                                                                  \
  s_##name_ = nullptr;                                                                                                 \
  if (NSIsSymbolNameDefinedWithHint("_" #name_, "CoreGraphics")) {                                                     \
    s_##name_ = (name_##_t)NSAddressOfSymbol(NSLookupAndBindSymbolWithHint("_" #name_, "CoreGraphics"));               \
  }

bool OSXScreen::isGlobalHotKeyOperatingModeAvailable()
{
  if (!s_testedForGHOM) {
    s_testedForGHOM = true;
    LOOKUP(_CGSDefaultConnection);
    LOOKUP(CGSGetGlobalHotKeyOperatingMode);
    LOOKUP(CGSSetGlobalHotKeyOperatingMode);
    s_hasGHOM = (s__CGSDefaultConnection != nullptr &&
                 s_CGSGetGlobalHotKeyOperatingMode != nullptr &&
                 s_CGSSetGlobalHotKeyOperatingMode != nullptr);
  }
  return s_hasGHOM;
}

void OSXScreen::setGlobalHotKeysEnabled(bool enabled)
{
  if (isGlobalHotKeyOperatingModeAvailable()) {
    CGSConnection conn = s__CGSDefaultConnection();

    CGSGlobalHotKeyOperatingMode mode;
    s_CGSGetGlobalHotKeyOperatingMode(conn, &mode);

    if (enabled && mode == CGSGlobalHotKeyDisable) {
      s_CGSSetGlobalHotKeyOperatingMode(conn, CGSGlobalHotKeyEnable);
    }
    else if (!enabled && mode == CGSGlobalHotKeyEnable) {
      s_CGSSetGlobalHotKeyOperatingMode(conn, CGSGlobalHotKeyDisable);
    }
  }
}

bool OSXScreen::getGlobalHotKeysEnabled()
{
  CGSGlobalHotKeyOperatingMode mode;
  if (isGlobalHotKeyOperatingModeAvailable()) {
    CGSConnection conn = s__CGSDefaultConnection();
    s_CGSGetGlobalHotKeyOperatingMode(conn, &mode);
  }
  else {
    mode = CGSGlobalHotKeyEnable;
  }
  return (mode == CGSGlobalHotKeyEnable);
}

#endif

//
// OSXScreen::HotKeyItem
//

OSXScreen::HotKeyItem::HotKeyItem(uint32_t keycode, uint32_t mask) : m_ref(nullptr), m_keycode(keycode), m_mask(mask)
{
  // do nothing
}

OSXScreen::HotKeyItem::HotKeyItem(EventHotKeyRef ref, uint32_t keycode, uint32_t mask)
    : m_ref(ref),
      m_keycode(keycode),
      m_mask(mask)
{
  // do nothing
}

EventHotKeyRef OSXScreen::HotKeyItem::getRef() const
{
  return m_ref;
}

bool OSXScreen::HotKeyItem::operator<(const HotKeyItem &x) const
{
  return (m_keycode < x.m_keycode || (m_keycode == x.m_keycode && m_mask < x.m_mask));
}

// Quartz event tap support for the secondary display. This makes sure that we
// will show the cursor if a local event comes in while deskflow has the cursor
// off the screen.
CGEventRef
OSXScreen::handleCGInputEventSecondary(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon)
{
  // this fix is really screwing with the correct show/hide behavior. it
  // should be tested better before reintroducing.
  return event;

  OSXScreen *screen = (OSXScreen *)refcon;
  if (screen->m_cursorHidden && type == kCGEventMouseMoved) {

    CGPoint pos = CGEventGetLocation(event);
    if (pos.x != screen->m_xCenter || pos.y != screen->m_yCenter) {

      LOG_DEBUG("show cursor on secondary, type=%d pos=%d,%d", type, pos.x, pos.y);
      screen->showCursor();
    }
  }
  return event;
}

// Quartz event tap support
CGEventRef OSXScreen::handleCGInputEvent(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon)
{
  OSXScreen *screen = (OSXScreen *)refcon;

  // While input is being synthesized on this screen, let events through instead
  // of forwarding them. The events we just posted would otherwise be captured
  // again and sent on to a client, delivering every keystroke twice.
  if (screen->m_fakeInputCount > 0) {
    return event;
  }

  // Synthetic clicks posted to replay a held-back press must pass through
  // untouched, otherwise they would be held back a second time.
  if (CGEventGetIntegerValueField(event, kCGEventSourceUserData) == kGestureReplayTag) {
    return event;
  }

  switch (type) {
  case kCGEventLeftMouseDown:
  case kCGEventRightMouseDown:
  case kCGEventOtherMouseDown:
    if (screen->onMouseButton(true, CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber) + 1)) {
      // Held back until we know whether this press is a gesture.
      return nullptr;
    }
    break;
  case kCGEventLeftMouseUp:
  case kCGEventRightMouseUp:
  case kCGEventOtherMouseUp:
    if (screen->onMouseButton(false, CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber) + 1)) {
      // Consumed as a gesture, or already replayed as a synthetic click.
      return nullptr;
    }
    break;
  case kCGEventLeftMouseDragged:
  case kCGEventRightMouseDragged:
  case kCGEventOtherMouseDragged:
  case kCGEventMouseMoved:
    // off-screen the cursor is frozen (see leave()), so fall through to consume
    // the move below instead of returning (leaking) it to local apps.
    screen->onMouseMove(event);
    break;
  case kCGEventScrollWheel:
    if (screen->onMouseWheel(
            screen->mapScrollWheelToDeskflow(CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis2)),
            screen->mapScrollWheelToDeskflow(CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis1))
        )) {
      // Consumed by a gesture.
      return nullptr;
    }
    break;
  case kCGEventKeyDown:
  case kCGEventKeyUp:
  case kCGEventFlagsChanged:
    screen->onKey(event);
    break;
  case kCGEventTapDisabledByTimeout:
    // Re-enable our event-tap if we still have accessibility permissions
    if (screen->checkAXPermissions()) {
      CGEventTapEnable(screen->m_eventTapPort, true);
      LOG_INFO("quartz event tap was disabled by timeout, re-enabling");
    }
    break;
  case kCGEventTapDisabledByUserInput:
    // The system can disable our tap when secure-event-input is toggled (e.g. by
    // a password field, DRM-protected media, or an accessibility/permission
    // change). Without re-enabling, every HID event bypasses the tap and leaks
    // straight to local apps until the service is restarted. The leak is
    // asymmetric and misleading: motion is invisible because leave() freezes the
    // cursor via CGAssociateMouseAndMouseCursorPosition(false), but right-click
    // and scroll-wheel act on the server's screen while the cursor is visually
    // on the client. Recover the same way as the timeout case.
    if (screen->checkAXPermissions()) {
      CGEventTapEnable(screen->m_eventTapPort, true);
      LOG_INFO("quartz event tap was disabled by user input, re-enabling");
    } else {
      LOG_ERR("quartz event tap was disabled by user input and not trusted");
    }
    break;
  case NX_NULLEVENT:
    break;
  default:
    if (type == NX_SYSDEFINED) {
      if (isMediaKeyEvent(event)) {
        LOG_VERBOSE("detected media key event");
        screen->onMediaKey(event);
      } else {
        LOG_VERBOSE("ignoring unknown system defined event");
        return event;
      }
      break;
    }

    LOG_VERBOSE("unknown quartz event type: 0x%02x", type);
  }

  if (screen->m_isOnScreen) {
    return event;
  } else {
    return nullptr;
  }
}

void OSXScreen::MouseButtonState::set(uint32_t button, EMouseButtonState state)
{
  bool newState = (state == kMouseButtonDown);
  m_buttons.set(button, newState);
}

bool OSXScreen::MouseButtonState::any()
{
  return m_buttons.any();
}

void OSXScreen::MouseButtonState::reset()
{
  m_buttons.reset();
}

void OSXScreen::MouseButtonState::overwrite(uint32_t buttons)
{
  m_buttons = std::bitset<NumButtonIDs>(buttons);
}

bool OSXScreen::MouseButtonState::test(uint32_t button) const
{
  return m_buttons.test(button);
}

int8_t OSXScreen::MouseButtonState::getFirstButtonDown() const
{
  if (m_buttons.any()) {
    for (unsigned short button = 0; button < m_buttons.size(); button++) {
      if (m_buttons.test(button)) {
        return button;
      }
    }
  }
  return -1;
}

char *OSXScreen::CFStringRefToUTF8String(CFStringRef aString)
{
  if (aString == nullptr) {
    return nullptr;
  }

  CFIndex length = CFStringGetLength(aString);
  CFIndex maxSize = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8);
  char *buffer = (char *)malloc(maxSize);

  if (!CFStringGetCString(aString, buffer, maxSize, kCFStringEncodingUTF8)) {
    free(buffer);
    buffer = nullptr;
  }

  return buffer;
}

void OSXScreen::waitForCarbonLoop() const
{
  if (*m_carbonLoopReady) {
    LOG_DEBUG("carbon loop already ready");
    return;
  }

  Lock lock(m_carbonLoopMutex);

  LOG_DEBUG("waiting for carbon loop");

  double timeout = Arch::time() + kCarbonLoopWaitTimeout;
  while (!m_carbonLoopReady->wait()) {
    if (Arch::time() > timeout) {
      LOG_DEBUG("carbon loop not ready, waiting again");
      timeout = Arch::time() + kCarbonLoopWaitTimeout;
    }
  }

  LOG_DEBUG("carbon loop ready");
}

std::string OSXScreen::getSecureInputApp() const
{
  if (IsSecureEventInputEnabled()) {
    int secureInputProcessPID = getSecureInputEventPID();
    if (secureInputProcessPID == 0)
      return "unknown";
    return getProcessName(secureInputProcessPID);
  }
  return "";
}

int getSecureInputEventPID()
{
  io_service_t service = MACH_PORT_NULL, service_root = MACH_PORT_NULL;
  mach_port_t masterPort;

  kern_return_t kr = IOMasterPort(MACH_PORT_NULL, &masterPort);
  if (kr != KERN_SUCCESS)
    return 0;

  // IO registry refuses to tap into the root level directly
  // as a workaround access the parent of the top user level
  service = IORegistryEntryFromPath(masterPort, kIOServicePlane ":/");
  IORegistryEntryGetParentEntry(service, kIOServicePlane, &service_root);

  std::unique_ptr<std::remove_pointer<CFTypeRef>::type, decltype(&CFRelease)> consoleUsers(
      IORegistryEntrySearchCFProperty(
          service_root, kIOServicePlane, CFSTR("IOConsoleUsers"), nullptr,
          kIORegistryIterateParents | kIORegistryIterateRecursively
      ),
      CFRelease
  );
  if (!consoleUsers)
    return 0;

  CFTypeID type = CFGetTypeID(consoleUsers.get());
  if (type != CFArrayGetTypeID())
    return 0;

  CFTypeRef dict = CFArrayGetValueAtIndex((CFArrayRef)consoleUsers.get(), 0);
  if (!dict)
    return 0;

  type = CFGetTypeID(dict);
  if (type != CFDictionaryGetTypeID())
    return 0;

  CFTypeRef secureInputPID = nullptr;
  CFDictionaryGetValueIfPresent((CFDictionaryRef)dict, CFSTR("kCGSSessionSecureInputPID"), &secureInputPID);

  if (secureInputPID == nullptr)
    return 0;

  type = CFGetTypeID(secureInputPID);
  if (type != CFNumberGetTypeID())
    return 0;

  auto pidRef = (CFNumberRef)secureInputPID;
  CFNumberType numberType = CFNumberGetType(pidRef);
  if (numberType != kCFNumberSInt32Type)
    return 0;

  int pid;
  CFNumberGetValue(pidRef, kCFNumberSInt32Type, &pid);
  return pid;
}

std::string getProcessName(int pid)
{
  if (!pid)
    return "";
  char buf[128];
  proc_name(pid, buf, sizeof(buf));
  return buf;
}

#pragma GCC diagnostic ignored "-Wdeprecated-declarations"

void setZeroSuppressionInterval()
{
  CGSetLocalEventsSuppressionInterval(0.0);
}

void avoidSupression()
{
  // avoid suppression of local hardware events
  // stkamp@users.sourceforge.net
  CGSetLocalEventsFilterDuringSupressionState(
      kCGEventFilterMaskPermitAllEvents, kCGEventSupressionStateSupressionInterval
  );
  CGSetLocalEventsFilterDuringSupressionState(
      (kCGEventFilterMaskPermitLocalKeyboardEvents | kCGEventFilterMaskPermitSystemDefinedEvents),
      kCGEventSupressionStateRemoteMouseDrag
  );
}

void logCursorVisibility()
{
  // CGCursorIsVisible is probably deprecated because its unreliable.
  if (!CGCursorIsVisible()) {
    LOG_WARN("cursor may not be visible");
  }
}

void avoidHesitatingCursor()
{
  // This used to be necessary to get smooth mouse motion on other screens,
  // but now is just to avoid a hesitating cursor when transitioning to
  // the primary (this) screen.
  CGSetLocalEventsSuppressionInterval(0.0001);
}

#pragma GCC diagnostic error "-Wdeprecated-declarations"
