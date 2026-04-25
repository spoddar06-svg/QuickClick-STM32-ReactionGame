# QuickClick — Reaction Time Trainer

A reaction time trainer built entirely in **ARM Thumb Assembly** on the **STM32F401RE NUCLEO** (Cortex-M4). No HAL, no libraries, no mercy — every peripheral is driven by direct register manipulation. 😮‍💨

Yes, the whole thing. In assembly. Every. Single. Line.

## Demo

[![QuickClick Demo](https://img.youtube.com/vi/8Pb5GQ4Sumc/0.jpg)](https://youtube.com/shorts/8Pb5GQ4Sumc)

---

## How It Works

A traffic light LED sequence counts down **Red → Yellow → Green**. The player must press the button as fast as possible the moment the green light appears. The game measures the reaction time in milliseconds, ranks the result, and keeps track of the best time in RAM.

### Features

- **Traffic light countdown** — Red (READY) → Yellow (SET) → Green (GO)
- **Millisecond reaction timer** — uses SysTick hardware timer for accurate measurement
- **False start detection** — pressing the button early triggers a penalty lockout
- **25% fake-out chance** — a STEADY screen appears after Yellow instead of Green to keep the player guessing
- **Random jitter delay** — unpredictable wait before the green light so the player can't time it by rhythm
- **Two difficulty modes** — Normal and Hardcore (tighter ranking thresholds, wider jitter window)
- **Rank system** — BOT / PRO / GOOD / TOO SLOW based on reaction time and difficulty
- **Best time tracking** — stored in RAM, persists across rounds
- **New record celebration** — all LEDs flash and a trumpet fanfare plays on a new best time
- **Breathing LED effect** — software PWM fades all LEDs in and out on the start screen
- **Bit-banged audio** — square wave tones on a passive buzzer for all game events

All of the above was implemented without a single `int main()`. 😮‍💨

### Ranking Thresholds

| Rank | Normal | Hardcore |
|------|--------|----------|
| BOT | < 50 ms | < 50 ms |
| PRO | 50 – 249 ms | 50 – 179 ms |
| GOOD | 250 – 399 ms | 180 – 249 ms |
| TOO SLOW | ≥ 400 ms | ≥ 250 ms |

---

## Hardware

| Component | Details |
|-----------|---------|
| Microcontroller | STM32F401RE NUCLEO (ARM Cortex-M4, 16 MHz) |
| Display | 16x2 LCD1602 (8-bit parallel mode) |
| Red LED | PB4 |
| Yellow LED | PB5 |
| Green LED | PB3 |
| Button | PB13 (internal pull-up, active low) |
| Buzzer | PB14 (passive, bit-banged PWM) |
| LCD RS | PA5 |
| LCD RW | PA6 |
| LCD EN | PA7 |
| LCD D0–D7 | PC0–PC7 |

---

## Software Architecture

Written entirely in **ARM Thumb Assembly** using Keil MDK. No CMSIS, no HAL, no C — every register is configured manually. What could go wrong? 😮‍💨

### Key Concepts Used

- **Direct GPIO register manipulation** — MODER, ODR, IDR, PUPDR configured via BIC/ORR bit masking
- **SysTick timer** — 1 ms timebase at 16 MHz (LOAD = 15999), COUNTFLAG polled for precise delays and reaction timing
- **Galois LFSR** — 16-bit maximal-length pseudo-random number generator for delays and fake-out probability
- **UDIV + MLS** — modulo operations for constraining random values to desired ranges (no native MOD instruction on ARM)
- **Bit-banged PWM** — software square wave generation for buzzer audio (frequency controlled by half-period busy-wait loop)
- **Software PWM** — breathing LED effect via duty-cycle loop (on-time proportional to brightness level 0–100)
- **Subroutine conventions** — PUSH/POP for register preservation, BL/BX LR for calls and returns
- **Literal pools** — LTORG directives placed strategically to keep 32-bit constants within LDR range

### RAM Variables

| Variable | Description |
|----------|-------------|
| `BEST_TIME` | Fastest reaction time recorded (ms), initialized to 9999 |
| `LFSR_STATE` | Current LFSR state for random number generation |
| `GAME_MODE` | 0 = Normal, 1 = Hardcore |

### Key Subroutines

| Subroutine | Description |
|------------|-------------|
| `PLAY_TONE` | Bit-banged square wave on PB14. R0 = half-period count (pitch), R1 = cycles (duration) |
| `DELAY_MS` | Blocking millisecond delay via SysTick COUNTFLAG polling |
| `DELAY_CHECK_BTN` | Delays R0 ms but returns immediately with R0=1 if button pressed early |
| `GET_RANDOM` | Advances 16-bit Galois LFSR, returns next pseudo-random value |
| `PULSE_WAIT` | Software PWM breathing LED effect, exits when button pressed |
| `WELCOME_SWEEP` | Boot attract animation cycling LEDs Red→Yellow→Green |
| `LCD_INIT` | HD44780 power-on initialization sequence |
| `LCD_PRINT_NUM` | Converts unsigned integer (0–9999) to decimal ASCII, suppresses leading zeros |

---

## Project Structure

```
QuickClick-STM32-ReactionGame/
└── main.s        # Complete ARM assembly source (~600 lines of questioning life choices)
```

---

## Build & Flash

1. Open **Keil MDK** and create a new project targeting the STM32F401RE
2. Add `main.s` to the project source files
3. Build and flash via ST-Link (on-board on the NUCLEO)

---

## License

MIT
