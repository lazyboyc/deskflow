/*
 * Deskflow -- mouse and keyboard sharing utility
 * SPDX-FileCopyrightText: (C) 2025 Chris Rizzitello <sithlord48@gmail.com>
 * SPDX-FileCopyrightText: (C) 2024 Synergy App Ltd
 * SPDX-License-Identifier: GPL-2.0-only WITH LicenseRef-OpenSSL-Exception
 */

#include "ScreenTests.h"

#include "common/Settings.h"
#include "gui/config/Screen.h"

void ScreenTests::initTestCase()
{
  // Settings builds its paths on first use and prefers the developer's real
  // config, and anything written there is locked through QSettings. Nothing has
  // constructed it yet, so redirect it first; reading the current path is what
  // constructs the singleton, which is why Settings::setSettingsFile() alone
  // would be too late. Settings only reads these variables on non-Windows
  // platforms, so the explicit redirect below stays as the fallback there.
  QDir dir;
  QVERIFY(dir.mkpath(m_settingsPath));
  qputenv("XDG_CONFIG_HOME", QDir::current().filePath(m_settingsPath).toUtf8());
  qputenv("XDG_STATE_HOME", QDir::current().filePath(m_settingsPath).toUtf8());

  QFile oldSettings(m_settingsFile);
  if (oldSettings.exists())
    oldSettings.remove();

  Settings::setSettingsFile(m_settingsFile);
  Settings::setStateFile(m_stateFile);
}

void ScreenTests::basicFunctionality()
{
  Screen screen;
  QVERIFY(screen.isNull());

  screen.setName("stub");
  QVERIFY(!screen.isNull());

  screen.saveSettings(Settings::proxy());
  screen.loadSettings(Settings::proxy());
  QCOMPARE("stub", screen.name());
}

QTEST_MAIN(ScreenTests)
