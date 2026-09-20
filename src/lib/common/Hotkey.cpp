/*
 * Deskflow -- mouse and keyboard sharing utility
 * SPDX-FileCopyrightText: (C) 2025 - 2026 Chris Rizzitello <sithlord48@gmail.com>
 * SPDX-FileCopyrightText: (C) 2012 - 2016 Synergy App Ltd
 * SPDX-FileCopyrightText: (C) 2008 Volker Lanz <vl@fidra.de>
 * SPDX-License-Identifier: GPL-2.0-only WITH LicenseRef-OpenSSL-Exception
 */

#include "Hotkey.h"

#include <QSettings>

QString Hotkey::text() const
{
  if (m_trigger == Trigger::Gesture) {
    return kGesture.arg(m_gestureButton, m_gestureDirection);
  }

  return m_keySequence.isMouseButton() ? kMousebutton.arg(m_keySequence.toString())
                                       : kKeystroke.arg(m_keySequence.toString());
}

const QStringList &Hotkey::gestureButtonNames()
{
  // The left button is excluded on purpose: it is the primary click/drag
  // button, and holding its presses back for gesture recognition would break
  // normal clicking everywhere.
  static const QStringList s_names = {QStringLiteral("middle"), QStringLiteral("right")};
  return s_names;
}

const QStringList &Hotkey::gestureDirectionNames()
{
  static const QStringList s_names = {
      QStringLiteral("left"),       QStringLiteral("right"),      QStringLiteral("up"),          QStringLiteral("down"),
      QStringLiteral("upleft"),     QStringLiteral("upright"),    QStringLiteral("downleft"),    QStringLiteral("downright"),
      QStringLiteral("scrollup"),   QStringLiteral("scrolldown"), QStringLiteral("scrollleft"), QStringLiteral("scrollright")
  };
  return s_names;
}

const QStringList &Hotkey::gestureDragDirectionNames()
{
  static const QStringList s_names = {
      QStringLiteral("left"),   QStringLiteral("right"), QStringLiteral("up"),  QStringLiteral("down"),
      QStringLiteral("upleft"), QStringLiteral("upright"), QStringLiteral("downleft"), QStringLiteral("downright")
  };
  return s_names;
}

void Hotkey::setGesture(const QString &button, const QString &direction)
{
  if (!gestureButtonNames().contains(button)) {
    return;
  }

  // A direction is either a single name ("up") or two drag segments joined
  // with '+' ("up+down"); the two segments must differ.
  const int plus = direction.indexOf('+');
  if (plus >= 0) {
    const QString first = direction.left(plus);
    const QString second = direction.mid(plus + 1);
    if (!gestureDragDirectionNames().contains(first) || !gestureDragDirectionNames().contains(second)
        || first == second) {
      return;
    }
  } else if (!gestureDirectionNames().contains(direction)) {
    return;
  }

  m_gestureButton = button;
  m_gestureDirection = direction;
  m_trigger = Trigger::Gesture;
}

Action &Hotkey::actionAt(int index)
{
  return m_actions[index];
}

void Hotkey::addAction(const Action &action)
{
  if (m_actions.contains(action))
    return;
  m_actions.append(action);
}

void Hotkey::removeActionAt(int index)
{
  if (index < 0 || index >= m_actions.size())
    return;
  m_actions.removeAt(index);
}

void Hotkey::loadSettings(QSettings &settings)
{
  m_keySequence.loadSettings(settings);

  m_trigger = static_cast<Trigger>(settings.value(kTrigger, static_cast<int>(Trigger::KeySequence)).toInt());
  m_gestureButton = settings.value(kGestureButton, m_gestureButton).toString();
  m_gestureDirection = settings.value(kGestureDirection, m_gestureDirection).toString();
  m_note = settings.value(kNote, m_note).toString();

  m_actions.clear();
  int num = settings.beginReadArray(kSectionActions);
  for (int i = 0; i < num; i++) {
    settings.setArrayIndex(i);
    Action a;
    a.loadSettings(settings);
    m_actions.append(a);
  }

  settings.endArray();
}

void Hotkey::saveSettings(QSettings &settings) const
{
  m_keySequence.saveSettings(settings);

  settings.setValue(kTrigger, static_cast<int>(m_trigger));
  settings.setValue(kGestureButton, m_gestureButton);
  settings.setValue(kGestureDirection, m_gestureDirection);
  if (!m_note.isEmpty()) {
    settings.setValue(kNote, m_note);
  } else {
    settings.remove(kNote);
  }

  settings.beginWriteArray(kSectionActions);
  for (int i = 0; i < m_actions.size(); i++) {
    settings.setArrayIndex(i);
    m_actions.at(i).saveSettings(settings);
  }
  settings.endArray();
}

bool Hotkey::operator==(const Hotkey &hk) const
{
  return m_trigger == hk.trigger() && m_keySequence == hk.keySequence() && m_gestureButton == hk.gestureButton() &&
         m_gestureDirection == hk.gestureDirection() && m_note == hk.note() && m_actions == hk.actions();
}

QTextStream &operator<<(QTextStream &outStream, const Hotkey &hotkey)
{
  // Don't write a config if there is no actions
  if (hotkey.actions().size() == 0)
    return outStream;

  QString outText = QStringLiteral("\t%1 = ").arg(hotkey.text());
  for (int i = 0; i < hotkey.actions().size(); i++) {
    outText.append(hotkey.actions().at(i).text());
    if (i != hotkey.actions().size() - 1) {
      outText.append(QStringLiteral(", "));
    }
  }
  outText.append(QStringLiteral("\n"));

  outStream << outText;
  return outStream;
}
