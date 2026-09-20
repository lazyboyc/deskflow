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
  m_showingNote = false;
  m_note.clear();
  m_points.clear();
  m_lastPos = QCursor::pos();
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

void GestureTrailOverlay::showNote(const QString &note)
{
  if (note.isEmpty()) {
    return;
  }

  // Fixed position: horizontally centred on the screen the mouse is on, about
  // one third of the screen height below the middle.
  const QPoint cursor = QCursor::pos();
  QScreen *screen = QGuiApplication::screenAt(cursor);
  if (screen == nullptr) {
    screen = QGuiApplication::primaryScreen();
  }
  const QRect geom = screen->geometry();
  m_note = note;
  m_notePos = QPointF(geom.center().x(), geom.top() + geom.height() * 2.0 / 3.0);
  m_showingNote = true;
  m_points.clear();
  setGeometry(QGuiApplication::primaryScreen()->virtualGeometry());
  show();
  applyNativeOverlayWindow();
#ifdef Q_OS_MACOS
  [[reinterpret_cast<NSView *>(winId()) window] orderFrontRegardless];
#endif
  update();

  QTimer::singleShot(600, this, [this] {
    m_showingNote = false;
    hide();
    update();
  });
}

void GestureTrailOverlay::pollCursor()
{
  const QPointF pos = QCursor::pos();
  m_lastPos = pos;
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

  QPainter painter(this);
  painter.setRenderHint(QPainter::Antialiasing);

  if (m_showingNote) {
    // A toast centred on the fixed note position (screen centre, lower third).
    QFont font = painter.font();
    font.setPointSizeF(font.pointSizeF() * 2);
    painter.setFont(font);
    const QFontMetrics metrics(font);
    const QRectF textRect = metrics.boundingRect(m_note);
    const QSizeF pad(16, 16); // equal border on all sides
    const qreal w = textRect.width() + pad.width() * 2;
    const qreal h = textRect.height() + pad.height() * 2;
    QRectF rect(m_notePos.x() - w / 2, m_notePos.y() - h / 2, w, h);
    // Keep the toast inside the virtual desktop.
    const QRectF bounds = geometry();
    rect.moveLeft(qBound(bounds.left() + 4, rect.left(), bounds.right() - rect.width() - 4));
    rect.moveTop(qBound(bounds.top() + 4, rect.top(), bounds.bottom() - rect.height() - 4));

    painter.setPen(Qt::NoPen);
    painter.setBrush(QColor(30, 30, 30, 200));
    painter.drawRoundedRect(rect, 6, 6);
    painter.setPen(QColor(255, 255, 255, 230));
    painter.drawText(rect, Qt::AlignCenter, m_note);
    return;
  }

  if (m_points.size() < 2) {
    return;
  }

  QPen pen(QColor(0, 122, 255, 170)); // translucent blue
  pen.setWidthF(3.0);
  pen.setCapStyle(Qt::RoundCap);
  pen.setJoinStyle(Qt::RoundJoin);
  painter.setPen(pen);
  painter.drawPolyline(m_points);

  // Mark the current head of the trail.
  painter.setPen(Qt::NoPen);
  painter.setBrush(QColor(0, 122, 255, 220));
  painter.drawEllipse(m_points.last(), 4.0, 4.0);
}
