/*******************************************************************************
 * Bluenumi Clock Firmware
 * Version 001
 *
 * Copyright (C) Sean Voisen. All rights reserved.
 * Last Modified: 10/30/2011
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
 ******************************************************************************/
 
#include <avr/interrupt.h> // Used for adding interrupts
#include "Wire.h" // Used for communicating with RTC
#include "DS1307RTC.h" // Ditto

/*******************************************************************************
 * Pin Mappings
 /*****************************************************************************/
#define SECONDS0_PIN 9 // LED under 10s hour
#define SECONDS1_PIN 10 // LED under 1s hour
#define SECONDS2_PIN 11 // LED under 10s minute
#define SECONDS3_PIN 3 // LED under 1s minute
#define DATA_PIN 13 // Data input to A6278 shift registers
#define LATCH_PIN 12 // Latch control for A6278 shift registers
#define CLK_PIN 6 // Clock for A6278 shift registers
#define OE_PIN 7 // Output enable on A6278 shift registers, active low
#define AMPM_PIN 0 // Both RX and used for AMPM indicator LED
#define ALRM_PIN 1 // Both TX and used for alarm indicator LED
#define PIEZO_PIN 8 // Piezo alarm
#define HZ_PIN 4 // 1 Hz pulse from DS1307 RTC
#define TIME_BTN_PIN 5 // Time set/left button
#define ALRM_BTN_PIN 2 // Alarm set/right button

#define SDA_PIN 4 // Analog pin, used for 2wire communication to DS1307
#define SCL_PIN 5 // Analog pin, used for 2wire communicatino to DS1307

/*******************************************************************************
 * Mode Defines
 /*****************************************************************************/
#define RUN_MODE 0
#define RUN_BLANK_MODE 1
#define SET_TIME_MODE 2
#define SET_ALARM_MODE 3
#define SET_TIME_HR10 4
#define SET_TIME_HR1 5
#define SET_TIME_MIN10 6
#define SET_TIME_MIN1 7

/*******************************************************************************
 * Misc Defines
 /*****************************************************************************/
#define DEBOUNCE_INTERVAL 20 // Interval to wait when debouncing buttons
#define LONG_PRESS 3000 // Length of time that qualifies as a long button press
#define BLINK_DELAY 500 // Length of display blink on/off interval

/*******************************************************************************
 * Debug Defines
 /*****************************************************************************/
#define DEBUG true
#if DEBUG
#define DEBUG_BAUD 9600
#endif

/*******************************************************************************
 * Time/Alarm Variables
 /*****************************************************************************/
byte alarmHours, alarmMinutes, timeSetHours, timeSetMinutes = 0;
bool timeSetAmPm = false;

/*******************************************************************************
 * Misc Variables
 /*****************************************************************************/
const int numbers[] = {123, 96, 87, 118, 108, 62, 47, 112, 127, 124};  // Array translates BCD to 7-segment output
volatile boolean updateDisplay = true; // Set to true when time display needs updating
byte mode = RUN_MODE; // Default to run mode
volatile unsigned long timeSetButtonPressTime = 0; // Keeps track of when time (left) button was pressed
volatile unsigned long alarmSetButtonPressTime = 0; // Keeps track of when alarm (right) button was pressed

/**
 * Sets up the program before running the continuous loop()
 */
void setup()
{
#if DEBUG
Serial.begin(DEBUG_BAUD);
Serial.println("Bluenumi");
Serial.println("Firmware Version 001");
#endif
 
  // Set up pin modes
  pinMode(SECONDS0_PIN, OUTPUT);
  pinMode(SECONDS1_PIN, OUTPUT);
  pinMode(SECONDS2_PIN, OUTPUT);
  pinMode(SECONDS3_PIN, OUTPUT);
  pinMode(DATA_PIN, OUTPUT);
  pinMode(LATCH_PIN, OUTPUT);
  pinMode(CLK_PIN, OUTPUT);
  pinMode(OE_PIN, OUTPUT);
  pinMode(AMPM_PIN, OUTPUT);
  pinMode(ALRM_PIN, OUTPUT);
  pinMode(PIEZO_PIN, OUTPUT);
  pinMode(HZ_PIN, INPUT);
  pinMode(TIME_BTN_PIN, INPUT);
  pinMode(ALRM_BTN_PIN, INPUT);
 
  // Pull-up resistors for buttons and DS1307 square wave
  digitalWrite(HZ_PIN, HIGH);
  digitalWrite(TIME_BTN_PIN, HIGH);
  digitalWrite(ALRM_BTN_PIN, HIGH);
  
  // Enable output
  digitalWrite(OE_PIN, LOW);
  
  // Arduino environment has only 2 interrupts, here we add a 3rd interrupt on Arduino digital pin 4 (PCINT20 XCK/TO)
  // This interrupt will be used to interface with the DS1307RTC square wave, and will be called every second (1Hz)
  PCICR |= (1 << PCIE2);
  PCMSK2 |= (1 << PCINT18); // Alarm button
  PCMSK2 |= (1 << PCINT20); // RTC square wave
  PCMSK2 |= (1 << PCINT21); // Time button

  // Start 2-wire communication with DS1307
  DS1307RTC.begin();
  
  // Check CH bit in DS1307, if it's 1 then the clock is not started
  //if (!DS1307RTC.isRunning()) 
  {
#if DEBUG
Serial.println("RTC not running; switching to set time mode");
#endif
    // Clock is not running, probably powering up for the first time, change mode to set time
    changeMode(SET_TIME_MODE);
    DS1307RTC.setDateTime(0, 0, 12, 1, 1, 1, 10, true, true, true, 0x10);
  }
}

/**
 * This function runs continously as long as the clock is powered on. When the clock is not
 * powered on the DS1307 will continue to keep time as long as it has a battery :)
 */
void loop()
{
  // Take care of any button presses first
  if (timeSetButtonPressTime > 0)
    handleTimeButtonPress();
  
  if (alarmSetButtonPressTime > 0)
    handleAlarmButtonPress();
  
  switch (mode) 
  {
    case RUN_MODE:
      handleRunMode();
      break;
    
    case RUN_BLANK_MODE:
      break;
      
    case SET_TIME_MODE:
      handleSetTimeMode();
      break;
      
    case SET_ALARM_MODE:
      break;
  }
}

void changeMode(byte newMode)
{
  switch(mode)
  {
    case SET_TIME_MODE:
      fetchTime(&timeSetHours, &timeSetMinutes, &timeSetAmPm);
      break;
  }

  mode = newMode;
}

void handleRunMode()
{
  if (updateDisplay) 
  { 
    // Only update time display as necessary
    outputTime();
    updateDisplay = false;
  }
}

void handleSetTimeMode()
{
  // updateBlink() will be true when time should be displayed
  if (updateBlink()) 
  { 
    showDisplay();
  }
  else 
  {
    blankDisplay();
  }
}

/**
 * Used for blinking the display on and off. Determines if the display should be on (true) or off (false) using
 * a set interval BLINK_DELAY.
 */
boolean updateBlink()
{
  static unsigned long lastBlinkTime = 0;
  static boolean blinkOn = true;

  if (millis() - lastBlinkTime >= BLINK_DELAY) 
  {
    blinkOn = !blinkOn;
    lastBlinkTime = millis();
  }

  return blinkOn;
}

bool fetchTime(byte* hour, byte* minute, bool* ampm)
{
  byte second, dayOfWeek, dayOfMonth, month, year;
  bool twelveHourMode;
  DS1307RTC.getDateTime(&second, minute, hour, &dayOfWeek, &dayOfMonth, &month, &year, &twelveHourMode, ampm);
  
  return true;
}

/**
 * Fetches the time from the DS1307 RTC and displays the time on the numitrons.
 */
void outputTime()
{
  byte minute, hour;
  bool ampm;
  fetchTime(&hour, &minute, &ampm);

#if DEBUG
Serial.print("Got time from RTC: ");
Serial.print(hour, DEC);
Serial.print(":");
Serial.println(minute, DEC);
#endif
  
  digitalWrite(LATCH_PIN, LOW);
  shiftOut(DATA_PIN, CLK_PIN, MSBFIRST, numbers[hour/10]);
  shiftOut(DATA_PIN, CLK_PIN, MSBFIRST, numbers[hour%10]);
  shiftOut(DATA_PIN, CLK_PIN, MSBFIRST, numbers[minute/10]);
  shiftOut(DATA_PIN, CLK_PIN, MSBFIRST, numbers[minute%10]);
  digitalWrite(LATCH_PIN, HIGH);
  
  digitalWrite(AMPM_PIN, (ampm ? HIGH : LOW)); // Also output AMPM indicator light
}

void timeButtonPressed()
{
  static unsigned long lastInterruptTime = 0;
  unsigned long interruptTime = millis();
  
  if (interruptTime - lastInterruptTime > DEBOUNCE_INTERVAL) 
    timeSetButtonPressTime = interruptTime;
  
  lastInterruptTime = interruptTime;
}

void alarmButtonPressed()
{
  static unsigned long lastInterruptTime = 0;
  unsigned long interruptTime = millis();
  
  if (interruptTime - lastInterruptTime > DEBOUNCE_INTERVAL) 
    alarmSetButtonPressTime = interruptTime;
  
  lastInterruptTime = interruptTime;
}

void setTimeReleased()
{
}

void setAlarmReleased()
{
}

void handleTimeButtonPress()
{
#if DEBUG
Serial.println("Time button pressed");
#endif
  boolean longPress = false;
  
  while (digitalRead(TIME_BTN_PIN) == LOW) 
  {
    if (millis() - timeSetButtonPressTime >= LONG_PRESS) 
      longPress = true;
  }
  
  switch( mode ) 
  {
    case RUN_MODE:
      if (longPress) 
        changeMode(SET_TIME_MODE);

      break;
      
    case SET_TIME_MODE:
      if (longPress) 
      {
        // TODO: Save new time in DS1307
        changeMode(RUN_MODE);
      }
      else 
      {
      }
      break;
  }
  
  timeSetButtonPressTime = 0;
}

void handleAlarmButtonPress()
{
#if DEBUG
Serial.println("Alarm button pressed");
#endif
  boolean longPress = false;
  
  while (digitalRead(ALRM_BTN_PIN) == LOW) 
  {
    if (millis() - alarmSetButtonPressTime >= LONG_PRESS) 
      longPress = true;
  }
  
  switch( mode ) 
  {
    case RUN_MODE:
      if (longPress) 
        changeMode(SET_ALARM_MODE);

      break;
  }
  
  alarmSetButtonPressTime = 0;
}

/**
 * Blanks the entire display, both numitrons and all LEDs.
 */
void blankDisplay()
{
  digitalWrite(OE_PIN, HIGH);
  digitalWrite(SECONDS0_PIN, LOW);
  digitalWrite(SECONDS1_PIN, LOW);
  digitalWrite(SECONDS2_PIN, LOW);
  digitalWrite(SECONDS3_PIN, LOW);
  digitalWrite(AMPM_PIN, LOW);
  digitalWrite(ALRM_PIN, LOW);
}

void showDisplay()
{
  digitalWrite(OE_PIN, LOW);
}

/**
 * This interrupt will be called every time the DS1307 square wave pin changes or a button is pressed. 
 * For the RTC, at 1Hz this means this will be called twice per second (high to low, low to high).
 */
ISR (PCINT2_vect)
{
  // Instead of digitalRead, we'll read the port directly for Arduino digital pin 4 (which resides in PORTD)
  // This keeps the execution time of the interrupt a bit shorter
  
  // Check for RTC square wave low
  // Here, we look for when pin 4 (4th bit in PIND) is pulled low (value == 0), meaning 1 second has passed
  if ((PIND & 0x10) == 0) 
    updateDisplay = true;
  
  // Check for time button press (pulled low) on pin 5
  if ((PIND & 0x20) == 0)
    timeButtonPressed();

  // Check for alarm button press (pulled low) on pin 2
  if ((PIND & 0x04) == 0)
    alarmButtonPressed();
}

