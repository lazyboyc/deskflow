/*
 * Deskflow -- mouse and keyboard sharing utility
 * SPDX-FileCopyrightText: (C) 2026 Deskflow Contributors
 * SPDX-License-Identifier: GPL-2.0-only WITH LicenseRef-OpenSSL-Exception
 */

#include "GestureTrailOverlay.h"

#include <QCursor>
#include <QGuiApplication>
#include <QPainter>
#include <QPaintEvent>
#include <QScreen>
#include <QTimer>
#include <QWindow>

#ifdef Q_OS_MACOS
#import <AppKit/AppKit.h>
#endif

GestureTrailOverlay::GestureTrailOverlay(QWidget *parent) : QWidget(parent)
{
  // A frameless, translucent, click-through window that floats above everything.
  setWindowFlags(Qt::Tool | Qt::FramelessWindowHint | Qt::WindowStaysOnTopHint | Qt::WindowTransparentForInput);
  setAttribute(Qt::WA_TranslucentBackground);
  setAttribute(Qt::WA_ShowWithoutActivating);
  setAttribute(Qt::WA_TransparentForMouseEvents);
  // macOS: keep the overlay visible even while another app is frontmost, and
  // never let showing it activate this app or raise its other windows.
  setAttribute(Qt::WA_MacAlwaysShowToolWindow);
  if (windowHandle() != nullptr) {
    windowHandle()->setFlag(Qt::WindowDoesNotAcceptFocus);
  }

  m_pollTimer = new QTimer(this);
  m_pollTimer->setInterval(16); // ~60 fps
  connect(m_pollTimer, &QTimer::timeout, this, [this] { pollCursor(); });
}

void GestureTrailOverlay::applyNativeOverlayWindow()
{
#ifdef Q_OS_MACOS
  // Force the underlying NSWindow to be a non-activating panel. Without this,
  // showing the overlay activates the whole application, which drags the main
  // window (and every other window of the app) to the front.
  NSWindow *nsWindow = [reinterpret_cast<NSView *>(winId()) window];
  if (nsWindow == nil) {
    return;
  }
  nsWindow.styleMask = NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel;
  nsWindow.collectionBehavior =
      NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary |
      NSWindowCollectionBehaviorIgnoresCycle;
  nsWindow.ignoresMouseEvents = YES;
  nsWindow.opaque = NO;
  nsWindow.backgroundColor = NSColor.clearColor;
#endif
}

void GestureTrailOverlay::start()
{
  m_points.clear();
  setGeometry(QGuiApplication::primaryScreen()->virtualGeometry());
  show();
  applyNativeOverlayWindow();
#ifdef Q_OS_MACOS
  // Order the panel to the front without activating the application.
  [[reinterpret_cast<NSView *>(winId()) window] orderFrontRegardless];
#endif
  pollCursor();
  m_pollTimer->start();
}

void GestureTrailOverlay::stop()
{
  m_pollTimer->stop();
  hide();
  m_points.clear();
}

void GestureTrailOverlay::pollCursor()
{
  const QPointF pos = QCursor::pos();
  if (!m_points.isEmpty() && m_points.last() == pos) {
    return;
  }
  if (m_points.size() >= kMaxPoints) {
    m_points.remove(0, m_points.size() / 4);
  }
  m_points.append(pos);
  update();
}

void GestureTrailOverlay::paintEvent(QPaintEvent *event)
{
  Q_UNUSED(event)

  if (m_points.size() < 2) {
    return;
  }

  QPainter painter(this);
  painter.setRenderHint(QPainter::Antialiasing);

  QPen pen(QColor(255, 59, 48, 170)); // translucent red
  pen.setWidthF(3.0);
  pen.setCapStyle(Qt::RoundCap);
  pen.setJoinStyle(Qt::RoundJoin);
  painter.setPen(pen);
  painter.drawPolyline(m_points);

  // Mark the current head of the trail.
  painter.setPen(Qt::NoPen);
  painter.setBrush(QColor(255, 59, 48, 220));
  painter.drawEllipse(m_points.last(), 4.0, 4.0);
}
