/*
 * Deskflow -- mouse and keyboard sharing utility
 * SPDX-FileCopyrightText: (C) 2026 Deskflow Developers
 * SPDX-License-Identifier: GPL-2.0-only WITH LicenseRef-OpenSSL-Exception
 */

#include "KeySequenceTests.h"

#include "common/KeySequence.h"

void KeySequenceTests::toString_controlShiftPlus_usesNamedPlus()
{
  KeySequence sequence;

  sequence.appendKey(Qt::Key_Control, Qt::ControlModifier);
  sequence.appendKey(Qt::Key_Shift, Qt::ControlModifier | Qt::ShiftModifier);
  QVERIFY(sequence.appendKey(Qt::Key_Plus, Qt::ControlModifier | Qt::ShiftModifier));

  // Qt reports Command as Qt::ControlModifier on Apple platforms, and the config
  // language names that key "Super" so that the token matches the physical key.
#ifdef Q_OS_MACOS
  QCOMPARE(sequence.toString(), QStringLiteral("Super+Shift+Plus"));
#else
  QCOMPARE(sequence.toString(), QStringLiteral("Control+Shift+Plus"));
#endif
}

void KeySequenceTests::toString_metaModifier_matchesPhysicalKey()
{
  KeySequence sequence;

  sequence.appendKey(Qt::Key_Meta, Qt::MetaModifier);
  sequence.appendKey(Qt::Key_Alt, Qt::MetaModifier | Qt::AltModifier);
  QVERIFY(sequence.appendKey(Qt::Key_Plus, Qt::MetaModifier | Qt::AltModifier));

  // Qt reports the Control key as Qt::MetaModifier on Apple platforms, so the
  // config language must name it "Control" rather than "Meta".
#ifdef Q_OS_MACOS
  QCOMPARE(sequence.toString(), QStringLiteral("Control+Alt+Plus"));
#else
  QCOMPARE(sequence.toString(), QStringLiteral("Meta+Alt+Plus"));
#endif
}

QTEST_MAIN(KeySequenceTests)
