/*
 * Deskflow -- mouse and keyboard sharing utility
 * SPDX-FileCopyrightText: (C) 2025 - 2026 Chris Rizzitello <sithlord48@gmail.com>
 * SPDX-FileCopyrightText: (C) 2012 - 2016 Synergy App Ltd
 * SPDX-FileCopyrightText: (C) 2008 Volker Lanz <vl@fidra.de>
 * SPDX-License-Identifier: GPL-2.0-only WITH LicenseRef-OpenSSL-Exception
 */

#pragma once

#include <QList>
#include <QString>
#include <QStringList>
#include <QTextStream>

#include "common/Action.h"
#include "common/KeySequence.h"

class HotkeyDialog;
class ServerConfigDialog;
class QSettings;

class Hotkey
{
public:
  //! What triggers this binding
  enum class Trigger
  {
    KeySequence, //!< a key combination, written as keystroke(...)
    Gesture      //!< a mouse gesture, written as gesture(button,direction)
  };

  Hotkey() = default;

  QString text() const;

  Trigger trigger() const
  {
    return m_trigger;
  }
  void setTrigger(Trigger trigger)
  {
    m_trigger = trigger;
  }

  const KeySequence &keySequence() const
  {
    return m_keySequence;
  }
  void setKeySequence(const KeySequence &seq)
  {
    m_keySequence = seq;
  }

  const QString &gestureButton() const
  {
    return m_gestureButton;
  }
  const QString &gestureDirection() const
  {
    return m_gestureDirection;
  }
  //! Selects a gesture and switches the trigger to Trigger::Gesture. Unknown
  //! names are ignored so a hand edited settings file cannot produce a rule the
  //! server would reject.
  void setGesture(const QString &button, const QString &direction);

  //! Free-form user note (a name or purpose); shown in the GUI only
  const QString &note() const
  {
    return m_note;
  }
  void setNote(const QString &note)
  {
    m_note = note;
  }
  //! The trigger text plus the note, for display in the hotkey list
  QString displayText() const
  {
    return m_note.isEmpty() ? text() : QStringLiteral("%1 — %2").arg(text(), m_note);
  }

  //! Names accepted by the server for the button part of gesture(...)
  static const QStringList &gestureButtonNames();
  //! Names accepted by the server for the direction part of gesture(...)
  static const QStringList &gestureDirectionNames();
  //! The 8 drag directions, usable as segments of a two-segment gesture
  static const QStringList &gestureDragDirectionNames();

  const ActionList &actions() const
  {
    return m_actions;
  }

  Action &actionAt(int index);
  void addAction(const Action &action);
  void removeActionAt(int index);

  void loadSettings(QSettings &settings);
  void saveSettings(QSettings &settings) const;

  bool operator==(const Hotkey &hk) const;

private:
  Trigger m_trigger = Trigger::KeySequence;
  KeySequence m_keySequence = {};
  QString m_gestureButton = QStringLiteral("right");
  QString m_gestureDirection = QStringLiteral("left");
  QString m_note;
  ActionList m_actions = {};
  inline static const QString kSectionActions = QStringLiteral("actions");
  inline static const QString kMousebutton = QStringLiteral("mousebutton(%1)");
  inline static const QString kKeystroke = QStringLiteral("keystroke(%1)");
  inline static const QString kGesture = QStringLiteral("gesture(%1,%2)");
  inline static const QString kTrigger = QStringLiteral("trigger");
  inline static const QString kGestureButton = QStringLiteral("gestureButton");
  inline static const QString kGestureDirection = QStringLiteral("gestureDirection");
  inline static const QString kNote = QStringLiteral("note");
};

using HotkeyList = QList<Hotkey>;

QTextStream &operator<<(QTextStream &outStream, const Hotkey &hotkey);
