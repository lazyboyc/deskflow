/*
 * Deskflow -- mouse and keyboard sharing utility
 * SPDX-FileCopyrightText: (C) 2012 - 2016 Synergy App Ltd
 * SPDX-FileCopyrightText: (C) 2008 Volker Lanz <vl@fidra.de>
 * SPDX-License-Identifier: GPL-2.0-only WITH LicenseRef-OpenSSL-Exception
 */

#include "HotkeyDialog.h"
#include "ui_HotkeyDialog.h"

#include "widgets/KeySequenceWidget.h"

#include <QComboBox>

HotkeyDialog::HotkeyDialog(QWidget *parent, Hotkey &hotkey)
    : QDialog(parent, Qt::WindowTitleHint | Qt::WindowSystemMenuHint),
      ui{std::make_unique<Ui::HotkeyDialog>()},
      m_Hotkey(hotkey)
{
  ui->setupUi(this);

  ui->m_pTriggerType->addItem(tr("Keyboard shortcut"), static_cast<int>(Hotkey::Trigger::KeySequence));
  ui->m_pTriggerType->addItem(tr("Mouse gesture"), static_cast<int>(Hotkey::Trigger::Gesture));

  ui->m_pGestureButton->addItems(Hotkey::gestureButtonNames());
  ui->m_pGestureDirection->addItems(Hotkey::gestureDirectionNames());

  const bool isGesture = m_Hotkey.trigger() == Hotkey::Trigger::Gesture;

  ui->m_pKeySequenceWidgetHotkey->setText(isGesture ? QString() : m_Hotkey.text());

  ui->m_pTriggerType->setCurrentIndex(ui->m_pTriggerType->findData(static_cast<int>(m_Hotkey.trigger())));

  if (const int index = ui->m_pGestureButton->findText(m_Hotkey.gestureButton()); index >= 0) {
    ui->m_pGestureButton->setCurrentIndex(index);
  }
  if (const int index = ui->m_pGestureDirection->findText(m_Hotkey.gestureDirection()); index >= 0) {
    ui->m_pGestureDirection->setCurrentIndex(index);
  }

  connect(ui->m_pTriggerType, &QComboBox::currentIndexChanged, this, &HotkeyDialog::toggleTrigger);
  toggleTrigger();
}

HotkeyDialog::~HotkeyDialog() = default;

void HotkeyDialog::toggleTrigger()
{
  const bool isGesture = ui->m_pTriggerType->currentData().toInt() == static_cast<int>(Hotkey::Trigger::Gesture);

  ui->m_pKeySequenceWidgetHotkey->setVisible(!isGesture);
  ui->labelGestureButton->setVisible(isGesture);
  ui->m_pGestureButton->setVisible(isGesture);
  ui->labelGestureDirection->setVisible(isGesture);
  ui->m_pGestureDirection->setVisible(isGesture);
  ui->labelGestureHint->setVisible(isGesture);

  adjustSize();
}

void HotkeyDialog::accept()
{
  if (ui->m_pTriggerType->currentData().toInt() == static_cast<int>(Hotkey::Trigger::Gesture)) {
    // setGesture() also switches the trigger, and ignores names the server
    // would not accept.
    hotkey().setGesture(ui->m_pGestureButton->currentText(), ui->m_pGestureDirection->currentText());
    QDialog::accept();
    return;
  }

  if (!sequenceWidget()->valid())
    return;

  hotkey().setKeySequence(sequenceWidget()->keySequence());
  hotkey().setTrigger(Hotkey::Trigger::KeySequence);
  QDialog::accept();
}

const KeySequenceWidget *HotkeyDialog::sequenceWidget() const
{
  return ui->m_pKeySequenceWidgetHotkey;
}
