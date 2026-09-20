/*
 * Deskflow -- mouse and keyboard sharing utility
 * SPDX-FileCopyrightText: (C) 2026 Deskflow Contributors
 * SPDX-License-Identifier: GPL-2.0-only WITH LicenseRef-OpenSSL-Exception
 */

#pragma once

#include <QWidget>

/**
 * @brief Transparent fullscreen overlay that draws the mouse gesture trail.
 *
 * While a gesture button is held down the core asks the GUI (via ipc) to show
 * the trail so the user can see the stroke being recognised. The overlay is
 * click-through, always on top, and polls the global cursor position; the
 * mouse events themselves belong to the core's event tap, never to this window.
 */
class GestureTrailOverlay : public QWidget
{
  Q_OBJECT

public:
  explicit GestureTrailOverlay(QWidget *parent = nullptr);

  //! Show the overlay and start tracking the cursor.
  void start();
  //! Hide the overlay and discard the trail.
  void stop();
  //! Show the matched hotkey's note for a second where the trail ended.
  void showNote(const QString &note);

protected:
  void paintEvent(QPaintEvent *event) override;

private:
  void pollCursor();
  void applyNativeOverlayWindow();

  QTimer *m_pollTimer = nullptr;
  QPolygonF m_points;
  QPointF m_lastPos;
  //! Note toast state: drawn instead of the trail for one second
  bool m_showingNote = false;
  QString m_note;
  QPointF m_notePos;
  static constexpr int kMaxPoints = 4096;
};
