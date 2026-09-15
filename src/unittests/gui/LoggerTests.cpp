/*
 * Deskflow -- mouse and keyboard sharing utility
 * SPDX-FileCopyrightText: (C) 2025 Chris Rizzitello <sithlord48@gmail.com>
 * SPDX-FileCopyrightText: (C) 2024 Synergy App Ltd
 * SPDX-License-Identifier: GPL-2.0-only WITH LicenseRef-OpenSSL-Exception
 */

#include "LoggerTests.h"
#include "common/Settings.h"

#include "gui/Logger.h"

#include <QDir>
#include <QFile>
#include <QSignalSpy>

using namespace deskflow::gui;

void LoggerTests::initTestCase()
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

void LoggerTests::newLine()
{
  QSignalSpy spy(Logger::instance(), &Logger::newLine);
  QVERIFY(spy.isValid());

  Settings::setValue(Settings::Log::GuiDebug, true);
  Logger::instance()->handleMessage(QtDebugMsg, "stub", "test");

  QCOMPARE(spy.count(), 1);
  QVERIFY(qvariant_cast<QString>(spy.takeFirst().at(0)).contains("test"));
  Settings::setValue(Settings::Log::GuiDebug, false);
}

void LoggerTests::noNewLine()
{
  bool newLineEmitted = false;

  QSignalSpy spy(Logger::instance(), &Logger::newLine);
  QVERIFY(spy.isValid());

  Settings::setValue(Settings::Log::GuiDebug, false);
  Logger::instance()->handleMessage(QtDebugMsg, "stub", "test");
  QCOMPARE(spy.count(), 0);
  QVERIFY(!newLineEmitted);
}

QTEST_MAIN(LoggerTests)
