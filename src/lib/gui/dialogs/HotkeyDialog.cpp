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
  ui->m_pGestureDirection2->addItem(tr("(none)"));
  ui->m_pGestureDirection2->addItems(Hotkey::gestureDragDirectionNames());

  // A second segment only makes sense after one of the 8 drag directions.
  const auto updateSecondSegment = [this] {
    ui->labelGestureDirection2->setEnabled(Hotkey::gestureDragDirectionNames().contains(
        ui->m_pGestureDirection->currentText()));
    ui->m_pGestureDirection2->setEnabled(ui->labelGestureDirection2->isEnabled());
    if (!ui->m_pGestureDirection2->isEnabled()) {
      ui->m_pGestureDirection2->setCurrentIndex(0);
    }
  };
  connect(ui->m_pGestureDirection, &QComboBox::currentIndexChanged, ui->m_pGestureDirection2,
          [updateSecondSegment] { updateSecondSegment(); });

  const bool isGesture = m_Hotkey.trigger() == Hotkey::Trigger::Gesture;

  ui->m_pKeySequenceWidgetHotkey->setText(isGesture ? QString() : m_Hotkey.text());

  ui->m_pTriggerType->setCurrentIndex(ui->m_pTriggerType->findData(static_cast<int>(m_Hotkey.trigger())));

  if (const int index = ui->m_pGestureButton->findText(m_Hotkey.gestureButton()); index >= 0) {
    ui->m_pGestureButton->setCurrentIndex(index);
  }

  // The direction is either a single name ("up") or two segments ("up+down").
  const QString direction = m_Hotkey.gestureDirection();
  const int plus = direction.indexOf('+');
  const QString first = (plus >= 0) ? direction.left(plus) : direction;
  const QString second = (plus >= 0) ? direction.mid(plus + 1) : QString();

  if (const int index = ui->m_pGestureDirection->findText(first); index >= 0) {
    ui->m_pGestureDirection->setCurrentIndex(index);
  }
  if (second.isEmpty()) {
    ui->m_pGestureDirection2->setCurrentIndex(0);
  } else if (const int index = ui->m_pGestureDirection2->findText(second); index >= 0) {
    ui->m_pGestureDirection2->setCurrentIndex(index);
  }
  updateSecondSegment();

  ui->m_pEditNote->setText(m_Hotkey.note());

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
  ui->labelGestureDirection2->setVisible(isGesture);
  ui->m_pGestureDirection2->setVisible(isGesture);
  ui->labelGestureHint->setVisible(isGesture);

  adjustSize();
}

void HotkeyDialog::accept()
{
  // The note applies to both trigger types.
  hotkey().setNote(ui->m_pEditNote->text().trimmed());

  if (ui->m_pTriggerType->currentData().toInt() == static_cast<int>(Hotkey::Trigger::Gesture)) {
    // setGesture() also switches the trigger, and ignores names the server
    // would not accept.
    QString direction = ui->m_pGestureDirection->currentText();
    if (ui->m_pGestureDirection2->currentIndex() > 0) {
      direction += QLatin1Char('+') + ui->m_pGestureDirection2->currentText();
    }
    hotkey().setGesture(ui->m_pGestureButton->currentText(), direction);
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
