; ==========================================================
; FINAL PROJECT: QUICK CLICK -- Reaction Time Trainer

; DESCRIPTION:
;   A reaction-time game written in pure ARM assembly.
;   A traffic-light LED sequence (Red -> Yellow -> Green)
;   counts down, and the player must press a button as fast
;   as possible when the green light turns on. Pressing too
;   early is a false start. A 25% fake-out chance adds
;   unpredictability. Two difficulty modes (Normal/Hardcore)
;   tighten the ranking thresholds. The best time is stored
;   in RAM and a fanfare plays on a new record.
;
; HARDWARE CONNECTIONS:
;   Red LED   -> PB4      Yellow LED -> PB5
;   Green LED -> PB3      Button     -> PB13 (active low, pull-up)
;   Buzzer    -> PB14
;   LCD RS    -> PA5      RW -> PA6  EN -> PA7
;   LCD D0-D7 -> PC0-PC7
;
; RANKING THRESHOLDS:
;   Rank      Normal      Hardcore
;   BOT       < 50 ms     < 50 ms
;   PRO       50-249 ms   50-179 ms
;   GOOD      250-399 ms  180-249 ms
;   TOO SLOW  >= 400 ms   >= 250 ms
; ==========================================================

; ----------------------------------------------------------
; RAM VARIABLES (read/write data section)
; ----------------------------------------------------------
    AREA    MYDATA, DATA, READWRITE
    ALIGN
BEST_TIME       SPACE   4           ; Stores fastest reaction time (ms), init to 9999
LFSR_STATE      SPACE   4           ; Current state of random number generator
GAME_MODE       SPACE   4           ; Difficulty setting: 0 = Normal, 1 = Hardcore

; ----------------------------------------------------------
; CODE SECTION
; ----------------------------------------------------------
    AREA    MYCODE, CODE, READONLY
    EXPORT  Reset_Handler
    ALIGN

; ----------------------------------------------------------
; HARDWARE REGISTER ADDRESSES
; These are fixed memory addresses on the STM32F401RE that
; control clocks, GPIO pins, and the SysTick timer.
; ----------------------------------------------------------
RCC_AHB1ENR     EQU     0x40023830  ; Clock enable register for GPIO ports
GPIOA_MODER     EQU     0x40020000  ; GPIOA pin direction register
GPIOB_MODER     EQU     0x40020400  ; GPIOB pin direction register
GPIOC_MODER     EQU     0x40020800  ; GPIOC pin direction register
GPIOB_PUPDR     EQU     0x4002040C  ; GPIOB pull-up/pull-down register
GPIOA_ODR       EQU     0x40020014  ; GPIOA output register (write to drive pins)
GPIOB_ODR       EQU     0x40020414  ; GPIOB output register
GPIOB_IDR       EQU     0x40020410  ; GPIOB input register (read to sense pins)
GPIOC_ODR       EQU     0x40020814  ; GPIOC output register
STK_CTRL        EQU     0xE000E010  ; SysTick timer control register
STK_LOAD        EQU     0xE000E014  ; SysTick timer reload value

; ----------------------------------------------------------
; PIN BIT MASKS
; Each constant is a bitmask for a specific pin in the
; GPIO output/input register.
; ----------------------------------------------------------
RS              EQU     (1<<5)      ; PA5 -- LCD Register Select (0=command, 1=data)
EN              EQU     (1<<7)      ; PA7 -- LCD Enable pin (latches data on falling edge)
RED             EQU     (1<<4)      ; PB4 -- Red LED
YELLOW          EQU     (1<<5)      ; PB5 -- Yellow LED
GREEN           EQU     (1<<3)      ; PB3 -- Green LED
ALL_LEDS        EQU     (0x38)      ; PB3|PB4|PB5 -- all three LEDs at once
BTN             EQU     (1<<13)     ; PB13 -- Player button (reads 0 when pressed)
BUZZER          EQU     (1<<14)     ; PB14 -- Passive buzzer output

; ==========================================================
; RESET HANDLER -- program entry point after power-on/reset
; ==========================================================
Reset_Handler
    THUMB

; ===== 1. HARDWARE SETUP =====

    ; Turn on the clocks for GPIOA, GPIOB, and GPIOC.
    ; Without this, the GPIO registers do nothing.
    ; Bits 0, 1, 2 of AHB1ENR enable GPIOA, B, C respectively.
    LDR     R0, =RCC_AHB1ENR
    LDR     R1, [R0]
    ORR     R1, R1, #0x07           ; Set bits 0-2 to enable all three GPIO clocks
    STR     R1, [R0]

    ; Configure PA5, PA6, PA7 as output pins (LCD RS, RW, EN).
    ; The MODER register uses 2 bits per pin: 00=input, 01=output.
    ; We clear the 6 bits covering PA5-PA7, then write 01 for each pin.
    LDR     R0, =GPIOA_MODER
    LDR     R1, [R0]
    BIC     R1, R1, #(0x3F << 10)   ; Clear mode bits for PA5, PA6, PA7
    ORR     R1, R1, #(0x15 << 10)   ; Write 01 01 01 = output mode for each
    STR     R1, [R0]

    ; Configure PC0-PC7 as outputs (LCD 8-bit data bus D0-D7).
    ; 0x5555 = 0101 0101 0101 0101 in binary -- sets every pair to 01 (output).
    LDR     R0, =GPIOC_MODER
    LDR     R1, =0x00005555
    STR     R1, [R0]

    ; Configure GPIOB pins:
    ;   PB3/PB4/PB5 -> output (LEDs)
    ;   PB13        -> input  (button)
    ;   PB14        -> output (buzzer)
    LDR     R0, =GPIOB_MODER
    LDR     R1, [R0]
    BIC     R1, R1, #(0x3F << 6)    ; Clear mode bits for PB3, PB4, PB5
    ORR     R1, R1, #(0x15 << 6)    ; Set PB3/PB4/PB5 as outputs (01 each)
    BIC     R1, R1, #(0x3 << 26)    ; Clear PB13 mode bits -> stays as input (00)
    BIC     R1, R1, #(0x3 << 28)    ; Clear PB14 mode bits first
    ORR     R1, R1, #(0x1 << 28)    ; Set PB14 as output for buzzer
    STR     R1, [R0]

    ; Enable internal pull-up resistor on PB13 (the button pin).
    ; With pull-up: pin reads HIGH (1) when button is not pressed,
    ; and LOW (0) when the button is pressed (active-low logic).
    LDR     R0, =GPIOB_PUPDR
    LDR     R1, [R0]
    BIC     R1, R1, #(0x3 << 26)    ; Clear existing pull setting for PB13
    ORR     R1, R1, #(0x1 << 26)    ; Write 01 = pull-up enabled
    STR     R1, [R0]

    ; Configure SysTick timer to generate a tick every 1 millisecond.
    ; At 16 MHz, 1 ms = 16,000 clock cycles, so reload value = 15999.
    ; CTRL register: bit0=enable counter, bit2=use CPU clock (no prescaler).
    LDR     R0, =STK_LOAD
    LDR     R1, =15999              ; Counts down from 15999 to 0 = 1 ms
    STR     R1, [R0]
    LDR     R0, =STK_CTRL
    MOV     R1, #5                  ; Bit0=1 (enable), Bit2=1 (processor clock)
    STR     R1, [R0]

    ; Initialize RAM variables before game starts
    LDR     R0, =BEST_TIME
    LDR     R1, =9999               ; 9999 = no record set yet
    STR     R1, [R0]
    LDR     R0, =LFSR_STATE
    LDR     R1, =0xACE1             ; Seed for random number generator (must be non-zero)
    STR     R1, [R0]

    BL      LCD_INIT                ; Run LCD startup sequence

; ===== 2. WELCOME SCREEN + LED ATTRACT SEQUENCE =====

    BL      LCD_CLEAR
    MOV     R0, #0x80               ; 0x80 = LCD command to move cursor to line 1
    BL      LCD_CMD
    LDR     R0, =MSG_WELC1          ; Print "   WELCOME TO   "
    BL      LCD_PRINT_STR
    MOV     R0, #0xC0               ; 0xC0 = LCD command to move cursor to line 2
    BL      LCD_CMD
    LDR     R0, =MSG_WELC2          ; Print "  QUICK CLICK!  "
    BL      LCD_PRINT_STR
    BL      WELCOME_SWEEP           ; Flash LEDs in Red->Yellow->Green pattern twice

; ===== 3. MODE SELECTION =====
; The player selects difficulty by how long they hold the button.
; A quick click = Normal mode. Holding >= 1 second = Hardcore mode.
MODE_SELECT
    BL      LCD_CLEAR
    MOV     R0, #0x80
    BL      LCD_CMD
    LDR     R0, =MSG_MOD1           ; " CLICK = NORMAL "
    BL      LCD_PRINT_STR
    MOV     R0, #0xC0
    BL      LCD_CMD
    LDR     R0, =MSG_MOD2           ; " HOLD 1s = HARD "
    BL      LCD_PRINT_STR

    ; Wait here until the button is pressed (PB13 goes LOW)
WAIT_FOR_MODE_BTN
    LDR     R0, =GPIOB_IDR
    LDR     R1, [R0]
    TST     R1, #BTN                ; Test bit 13; nonzero = not pressed yet
    BNE     WAIT_FOR_MODE_BTN       ; Keep looping until press detected

    ; Once pressed, count milliseconds held.
    ; If we reach 1000 ms (1 second), branch to Hardcore.
    ; If button is released before 1000 ms, fall through to Normal.
    MOV     R5, #0                  ; R5 = hold duration counter (milliseconds)
HOLD_EVAL
    MOV     R0, #1
    BL      DELAY_MS                ; Wait 1 ms
    ADD     R5, R5, #1              ; Increment counter
    CMP     R5, #1000               ; Has button been held for 1 full second?
    BEQ     SET_HARD                ; Yes -> Hardcore mode
    LDR     R0, =GPIOB_IDR
    LDR     R1, [R0]
    TST     R1, #BTN                ; Is button still held down?
    BEQ     HOLD_EVAL               ; Still held -> keep counting
                                    ; Released before 1s -> fall through to Normal

SET_NORM
    ; Flash green LED as visual confirmation, store mode = 0 (Normal)
    LDR     R0, =GPIOB_ODR
    MOV     R1, #GREEN
    STR     R1, [R0]
    MOV     R0, #0
    LDR     R1, =GAME_MODE
    STR     R0, [R1]                ; GAME_MODE = 0
    LDR     R8, =MSG_MNOR1          ; R8/R9 hold the mode confirmation strings
    LDR     R9, =MSG_MNOR2
    B       WAIT_RELEASE_MODE

SET_HARD
    ; Flash red LED as visual confirmation, store mode = 1 (Hardcore)
    LDR     R0, =GPIOB_ODR
    MOV     R1, #RED
    STR     R1, [R0]
    MOV     R0, #1
    LDR     R1, =GAME_MODE
    STR     R0, [R1]                ; GAME_MODE = 1
    LDR     R8, =MSG_MHRD1
    LDR     R9, =MSG_MHRD2

    ; Wait for button to be physically released before continuing
WAIT_RELEASE_MODE
    LDR     R2, =GPIOB_IDR
    LDR     R3, [R2]
    TST     R3, #BTN                ; Nonzero = released
    BEQ     WAIT_RELEASE_MODE

SHOW_MODE
    ; Display the selected mode name for ~2 seconds, play a confirmation beep
    BL      LCD_CLEAR
    MOV     R0, #0x80
    BL      LCD_CMD
    MOV     R0, R8                  ; R8 points to mode name line 1
    BL      LCD_PRINT_STR
    MOV     R0, #0xC0
    BL      LCD_CMD
    MOV     R0, R9                  ; R9 points to mode name line 2
    BL      LCD_PRINT_STR
    LDR     R0, =6000               ; Frequency value for confirmation beep
    MOV     R1, #100                ; Duration of beep
    BL      PLAY_TONE
    LDR     R0, =1900               ; Hold mode screen for ~2 seconds total
    BL      DELAY_MS
    LDR     R0, =GPIOB_ODR
    MOV     R1, #0
    STR     R1, [R0]                ; Turn off all LEDs

; ===== 4. PRESS START SCREEN =====
; Shown between every round. All LEDs breathe in and out
; (software PWM) until the player presses the button.
GAME_HOME
    LDR     R0, =GPIOB_ODR
    MOV     R1, #0
    STR     R1, [R0]                ; Ensure LEDs are off
    BL      LCD_CLEAR
    MOV     R0, #0x80
    BL      LCD_CMD
    LDR     R0, =MSG_START          ; "  PRESS START   "
    BL      LCD_PRINT_STR
    BL      PULSE_WAIT              ; Breathing LED effect; returns when button pressed

    ; Wait for button to be fully released before starting the game
WAIT_RELEASE_START
    LDR     R0, =GPIOB_IDR
    LDR     R1, [R0]
    TST     R1, #BTN
    BEQ     WAIT_RELEASE_START

; ===== 5. GAME SEQUENCE =====

    BL      LCD_CLEAR
    MOV     R0, #0x80
    BL      LCD_CMD
    LDR     R0, =MSG_RDY            ; "  GET READY...  "
    BL      LCD_PRINT_STR

    ; Random pre-game delay (250-1249 ms) so the player cannot
    ; predict exactly when the red light will appear.
    ; We use UDIV + MLS to compute: delay = (random % 1000) + 250
    BL      GET_RANDOM              ; Returns a pseudo-random number in R0
    LDR     R1, =1000
    UDIV    R2, R0, R1              ; R2 = R0 / 1000
    MLS     R0, R2, R1, R0         ; R0 = R0 - (R2 * 1000)  -->  R0 mod 1000
    ADD     R0, R0, #250            ; R0 now in range 250 to 1249
    BL      DELAY_MS

    ; -----------------------------------------------------------
    ; RED LIGHT -- "READY..."
    ; The red LED turns on. The player must NOT press the button.
    ; DELAY_CHECK_BTN waits 850 ms; if the button is pressed
    ; during this window it returns 1 (false start).
    ; -----------------------------------------------------------
    MOV     R0, #0x80
    BL      LCD_CMD
    LDR     R0, =MSG_RED            ; "    READY...    "
    BL      LCD_PRINT_STR
    LDR     R0, =GPIOB_ODR
    MOV     R1, #RED                ; Turn on red LED only
    STR     R1, [R0]
    LDR     R0, =8000               ; High-pitched beep to signal red light
    MOV     R1, #150
    BL      PLAY_TONE
    LDR     R0, =850                ; 850 ms false-start detection window
    BL      DELAY_CHECK_BTN         ; Returns 0 = safe, 1 = pressed early
    CMP     R0, #1
    BNE     SAFE_RED
    B       FALSE_START             ; Button pressed during red -> penalty
SAFE_RED

    ; -----------------------------------------------------------
    ; YELLOW LIGHT -- "SET..."
    ; Same as red but switches to yellow LED. Another 850 ms window.
    ; -----------------------------------------------------------
    MOV     R0, #0x80
    BL      LCD_CMD
    LDR     R0, =MSG_YEL            ; "     SET...     "
    BL      LCD_PRINT_STR
    LDR     R0, =GPIOB_ODR
    MOV     R1, #YELLOW             ; Switch to yellow LED
    STR     R1, [R0]
    LDR     R0, =8000
    MOV     R1, #150
    BL      PLAY_TONE
    LDR     R0, =850
    BL      DELAY_CHECK_BTN
    CMP     R0, #1
    BNE     SAFE_YEL
    B       FALSE_START
SAFE_YEL

    ; -----------------------------------------------------------
    ; FAKE-OUT CHECK -- 25% chance
    ; After yellow, there is a 1-in-4 chance the game shows
    ; "STEADY..." and switches back to red instead of going green.
    ; We get a random number and check its lower 2 bits.
    ; Only value 0 (out of 0,1,2,3) triggers the fake-out.
    ; -----------------------------------------------------------
    BL      GET_RANDOM
    AND     R0, R0, #3              ; Keep lower 2 bits: result is 0, 1, 2, or 3
    CMP     R0, #0                  ; Only 0 triggers the fake-out (25% chance)
    BNE     SKIP_FAKEOUT            ; Not 0 -> skip fake-out, go to jitter

    MOV     R0, #0x80
    BL      LCD_CMD
    LDR     R0, =MSG_FAK            ; "   STEADY...    "
    BL      LCD_PRINT_STR
    LDR     R0, =GPIOB_ODR
    MOV     R1, #RED                ; Revert to red LED to reinforce "don't press"
    STR     R1, [R0]
    LDR     R0, =8000
    MOV     R1, #150
    BL      PLAY_TONE
    LDR     R0, =850
    BL      DELAY_CHECK_BTN         ; Still watching for false starts
    CMP     R0, #1
    BNE     SKIP_FAKEOUT
    B       FALSE_START
SKIP_FAKEOUT

    ; -----------------------------------------------------------
    ; RANDOM JITTER DELAY before green light
    ; An unpredictable wait so the player cannot time their press
    ; by counting. Every 250 ms a quiet "tension tick" plays.
    ; Normal mode: 500-1999 ms. Hardcore: 10-3009 ms.
    ; -----------------------------------------------------------
    BL      GET_RANDOM
    LDR     R1, =GAME_MODE
    LDR     R1, [R1]
    CMP     R1, #1                  ; Is Hardcore mode active?
    BEQ     CALC_HARD_JITTER

CALC_NORM_JITTER
    LDR     R1, =1500
    UDIV    R2, R0, R1
    MLS     R0, R2, R1, R0         ; R0 = random % 1500
    ADD     R0, R0, #500            ; Range: 500 to 1999 ms
    B       DO_JITTER

CALC_HARD_JITTER
    LDR     R1, =3000
    UDIV    R2, R0, R1
    MLS     R0, R2, R1, R0         ; R0 = random % 3000
    ADD     R0, R0, #10             ; Range: 10 to 3009 ms

DO_JITTER
    MOV     R8, R0                  ; R8 = total jitter time remaining (ms)

    ; Process jitter in 250 ms chunks. Each chunk plays a tick and
    ; checks for false starts. Leftover time < 250 ms is handled last.
JITTER_LP
    CMP     R8, #250
    BLT     JIT_REM                 ; Less than 250 ms left -> handle remainder
    LDR     R0, =4000               ; Low pitch tension tick sound
    MOV     R1, #20
    BL      PLAY_TONE
    MOV     R0, #250
    BL      DELAY_CHECK_BTN         ; Wait 250 ms, watching for early press
    CMP     R0, #1
    BNE     JIT_SAFE
    B       FALSE_START
JIT_SAFE
    SUBS    R8, R8, #250
    B       JITTER_LP
JIT_REM
    CMP     R8, #0
    BEQ     SAFE_GRN                ; No remainder -> go straight to green
    MOV     R0, R8
    BL      DELAY_CHECK_BTN         ; Wait out the remaining ms
    CMP     R0, #1
    BNE     SAFE_GRN
    B       FALSE_START
SAFE_GRN

    ; -----------------------------------------------------------
    ; GREEN LIGHT -- "GO!!!" -- reaction timer starts
    ; The green LED and buzzer fire at the same instant.
    ; We count how many 1 ms SysTick ticks pass before the
    ; player presses the button. That count = reaction time in ms.
    ; The SysTick COUNTFLAG (bit 16 of STK_CTRL) is set once per
    ; millisecond and automatically clears when read.
    ; -----------------------------------------------------------
    MOV     R0, #0x80
    BL      LCD_CMD
    LDR     R0, =MSG_GRN            ; "     GO!!!      "
    BL      LCD_PRINT_STR
    LDR     R0, =GPIOB_ODR
    MOV     R1, #GREEN
    ORR     R1, R1, #BUZZER         ; Turn on green LED and buzzer simultaneously
    STR     R1, [R0]

    MOV     R4, #0                  ; R4 = reaction time counter (milliseconds)
REACTION_LOOP
    LDR     R0, =STK_CTRL
    LDR     R1, [R0]
    TST     R1, #(1<<16)            ; Check COUNTFLAG: set every 1 ms
    BEQ     SKIP_INC                ; Not yet elapsed -> skip increment
    ADD     R4, R4, #1              ; 1 ms has passed -> increment timer
SKIP_INC
    LDR     R0, =GPIOB_IDR
    LDR     R1, [R0]
    TST     R1, #BTN                ; Is button still not pressed (reads HIGH)?
    BNE     REACTION_LOOP           ; Not pressed -> keep timing
    ; Button is now pressed -- R4 holds the reaction time in ms

    ; -----------------------------------------------------------
    ; RESULT PROCESSING
    ; Turn off LEDs, check if this is a new best time, display result.
    ; -----------------------------------------------------------
    LDR     R0, =GPIOB_ODR
    MOV     R1, #0
    STR     R1, [R0]                ; Turn off green LED and buzzer

    ; Compare reaction time (R4) against stored best time
    LDR     R1, =BEST_TIME
    LDR     R2, [R1]                ; R2 = current best time
    MOV     R5, #0                  ; R5 = new-record flag (0 = no new record)
    CMP     R4, R2                  ; Is new time less than best?
    BGE     NO_RECORD               ; No -> skip update
    STR     R4, [R1]                ; Yes -> save new best time to RAM
    MOV     R5, #1                  ; Set flag to trigger celebration later
NO_RECORD

    ; Display the player's reaction time on the LCD
    BL      LCD_CLEAR
    MOV     R0, #0x80
    BL      LCD_CMD
    LDR     R0, =MSG_TIME           ; "   YOUR TIME:   "
    BL      LCD_PRINT_STR
    MOV     R0, #0xC0
    BL      LCD_CMD
    LDR     R0, =MSG_PAD            ; 5 spaces to centre the number on line 2
    BL      LCD_PRINT_STR
    MOV     R0, R4                  ; Pass reaction time to print routine
    BL      LCD_PRINT_NUM           ; Prints as decimal (e.g. "342")
    LDR     R0, =MSG_MS             ; Append "ms"
    BL      LCD_PRINT_STR
    LDR     R0, =1500               ; Hold result on screen 1.5 seconds
    BL      DELAY_MS

    ; -----------------------------------------------------------
    ; RANK EVALUATION
    ; Compare reaction time against thresholds for the current mode.
    ; Result is printed on line 1; time stays on line 2.
    ; -----------------------------------------------------------
    MOV     R0, #0x80
    BL      LCD_CMD
    LDR     R1, =GAME_MODE
    LDR     R1, [R1]
    CMP     R1, #1
    BEQ     EVAL_HARD               ; Branch to tighter Hardcore thresholds

EVAL_NORM                           ; Normal mode: BOT<50, PRO<250, GOOD<400, else SLOW
    CMP     R4, #50
    BGE     CHK_PRO_N
    B       R_BOT
CHK_PRO_N
    CMP     R4, #250
    BGE     CHK_GOOD_N
    B       R_PRO
CHK_GOOD_N
    CMP     R4, #400
    BGE     IS_SLOW_N
    B       R_GOOD
IS_SLOW_N
    B       R_SLOW

EVAL_HARD                           ; Hardcore mode: BOT<50, PRO<180, GOOD<250, else SLOW
    CMP     R4, #50
    BGE     CHK_PRO_H
    B       R_BOT
CHK_PRO_H
    CMP     R4, #180
    BGE     CHK_GOOD_H
    B       R_PRO
CHK_GOOD_H
    CMP     R4, #250
    BGE     IS_SLOW_H
    B       R_GOOD
IS_SLOW_H
    B       R_SLOW

; Literal pool forced here so 32-bit constants stay within
; reachable range of the LDR pseudo-instructions above.
    B       SKIP_POOL1
    LTORG
SKIP_POOL1

; --- Print rank string and play corresponding sound ---

R_BOT
R_PRO
    ; BOT and PRO share this block; CMP distinguishes which string to use
    LDR     R0, =RANK_PRO
    CMP     R4, #50
    BGE     PRINT_PRO               ; time >= 50 ms -> PRO
    LDR     R0, =RANK_BOT           ; time < 50 ms  -> BOT (suspiciously fast)
PRINT_PRO
    BL      LCD_PRINT_STR
    LDR     R0, =8000               ; Descending three-tone fanfare for PRO/BOT
    MOV     R1, #100
    BL      PLAY_TONE
    LDR     R0, =6000
    MOV     R1, #100
    BL      PLAY_TONE
    LDR     R0, =4000
    MOV     R1, #200
    BL      PLAY_TONE
    B       R_DONE

R_GOOD
    LDR     R0, =RANK_GOOD
    BL      LCD_PRINT_STR
    LDR     R0, =7000               ; Two quick beeps for GOOD rank
    MOV     R1, #100
    BL      PLAY_TONE
    MOV     R0, #50
    BL      DELAY_MS
    LDR     R0, =7000
    MOV     R1, #100
    BL      PLAY_TONE
    B       R_DONE

R_SLOW
    LDR     R0, =RANK_SLOW
    BL      LCD_PRINT_STR
    LDR     R0, =15000              ; Single long low-pitched "womp" for TOO SLOW
    MOV     R1, #300
    BL      PLAY_TONE
    B       R_DONE

R_DONE
    LDR     R0, =2000               ; Show rank for 2 seconds
    BL      DELAY_MS
    CMP     R5, #1                  ; Was a new record set this round?
    BEQ     SHOW_BLINKING_RECORD    ; Yes -> go to fanfare celebration

    ; No new record -- show best time and return to start screen
    BL      LCD_CLEAR
    MOV     R0, #0x80
    BL      LCD_CMD
    LDR     R0, =MSG_BEST           ; "   BEST TIME:   "
    BL      LCD_PRINT_STR
    MOV     R0, #0xC0
    BL      LCD_CMD
    LDR     R0, =MSG_PAD
    BL      LCD_PRINT_STR
    LDR     R1, =BEST_TIME
    LDR     R0, [R1]                ; Load best time from RAM
    BL      LCD_PRINT_NUM
    LDR     R0, =MSG_MS
    BL      LCD_PRINT_STR
    LDR     R0, =3000               ; Show best time for 3 seconds
    BL      DELAY_MS
    B       GAME_HOME               ; Loop back to press-start screen


; -----------------------------------------------------------
; FALSE START PENALTY ROUTINE
; Triggered when button is pressed during red/yellow/fake-out.
; Displays "TOO EARLY!", plays a penalty sound, waits 1.5 s,
; then returns to the start screen (best time is NOT affected).
; -----------------------------------------------------------
FALSE_START
    LDR     R0, =GPIOB_ODR
    MOV     R1, #0
    STR     R1, [R0]                ; Turn off all LEDs immediately
    MOV     R0, #0x80
    BL      LCD_CMD
    LDR     R0, =MSG_FALSE          ; "   TOO EARLY!   "
    BL      LCD_PRINT_STR
    LDR     R0, =5000               ; Mid-pitched first penalty tone
    MOV     R1, #200
    BL      PLAY_TONE
    LDR     R0, =14000              ; Lower second penalty tone ("womp womp")
    MOV     R1, #400
    BL      PLAY_TONE
    LDR     R0, =1500               ; 1.5 second lockout before next attempt
    BL      DELAY_MS
    B       GAME_HOME


; -----------------------------------------------------------
; NEW RECORD CELEBRATION ROUTINE
; Displays "NEW RECORD!" with the new best time, lights all
; LEDs, and plays a short trumpet fanfare.
; -----------------------------------------------------------
SHOW_BLINKING_RECORD
    BL      LCD_CLEAR
    MOV     R0, #0x80
    BL      LCD_CMD
    LDR     R0, =MSG_NEW            ; "  NEW RECORD!   "
    BL      LCD_PRINT_STR
    MOV     R0, #0xC0
    BL      LCD_CMD
    LDR     R0, =MSG_PAD
    BL      LCD_PRINT_STR
    LDR     R1, =BEST_TIME
    LDR     R0, [R1]                ; Display the newly saved best time
    BL      LCD_PRINT_NUM
    LDR     R0, =MSG_MS
    BL      LCD_PRINT_STR

    LDR     R0, =GPIOB_ODR
    MOV     R1, #ALL_LEDS           ; Flash all three LEDs during fanfare
    STR     R1, [R0]

    ; Trumpet fanfare sequence: Ta - DA - (rest) - Ta - Da - DAAAA!
    LDR     R0, =8000               ; Note 1: short high note (Ta)
    MOV     R1, #80
    BL      PLAY_TONE
    LDR     R0, =6000               ; Note 2: longer mid note (DA)
    MOV     R1, #150
    BL      PLAY_TONE
    MOV     R0, #50
    BL      DELAY_MS                ; Brief rest
    LDR     R0, =8000               ; Note 3: short high note (Ta)
    MOV     R1, #80
    BL      PLAY_TONE
    LDR     R0, =6000               ; Note 4: short mid note (Da)
    MOV     R1, #80
    BL      PLAY_TONE
    LDR     R0, =4500               ; Note 5: long low note -- big finish (DAAAA!)
    MOV     R1, #600
    BL      PLAY_TONE

    LDR     R0, =GPIOB_ODR
    MOV     R1, #0
    STR     R1, [R0]                ; LEDs off after fanfare
    LDR     R0, =1500
    BL      DELAY_MS
    B       GAME_HOME               ; Back to start screen for next round


    B       SKIP_POOL2
    LTORG
SKIP_POOL2


; ==========================================================
; SUBROUTINES
; ==========================================================

; -----------------------------------------------------------
; SUBROUTINE: PLAY_TONE
; Generates a square wave on the buzzer pin (PB14) using a
; software busy-wait loop -- this is called "bit-banged PWM".
; The pin is toggled HIGH and LOW repeatedly to create sound.
; INPUT:  R0 = half-period delay count (larger = lower pitch)
;         R1 = number of complete on/off cycles (longer = longer sound)
; OUTPUT: None
; -----------------------------------------------------------
PLAY_TONE
    PUSH    {R4-R6, LR}
    MOV     R4, R1                  ; R4 = cycle counter
PT_LOOP
    ; Set buzzer pin HIGH (start of one cycle)
    LDR     R2, =GPIOB_ODR
    LDR     R3, [R2]
    ORR     R3, R3, #BUZZER         ; Set PB14 bit without disturbing other pins
    STR     R3, [R2]
    MOV     R5, R0                  ; R5 = delay count for HIGH phase
PT_D1   SUBS    R5, R5, #1          ; Busy-wait (counts down to zero)
    BNE     PT_D1

    ; Set buzzer pin LOW (second half of cycle)
    LDR     R2, =GPIOB_ODR
    LDR     R3, [R2]
    BIC     R3, R3, #BUZZER         ; Clear PB14 bit
    STR     R3, [R2]
    MOV     R5, R0                  ; Reset delay for LOW phase
PT_D2   SUBS    R5, R5, #1
    BNE     PT_D2

    SUBS    R4, R4, #1              ; One full cycle done
    BNE     PT_LOOP                 ; Repeat until all cycles complete
    POP     {R4-R6, PC}


; -----------------------------------------------------------
; SUBROUTINE: WELCOME_SWEEP
; Cycles LEDs Red -> Yellow -> Green -> Yellow twice as a
; boot-up attract animation to show hardware is working.
; INPUT/OUTPUT: None
; -----------------------------------------------------------
WELCOME_SWEEP
    PUSH    {R4, LR}
    MOV     R4, #2                  ; R4 = repeat counter (2 full sweeps)
WS_LP
    LDR     R0, =GPIOB_ODR
    MOV     R1, #RED
    STR     R1, [R0]
    LDR     R0, =150
    BL      DELAY_MS
    LDR     R0, =GPIOB_ODR
    MOV     R1, #YELLOW
    STR     R1, [R0]
    LDR     R0, =150
    BL      DELAY_MS
    LDR     R0, =GPIOB_ODR
    MOV     R1, #GREEN
    STR     R1, [R0]
    LDR     R0, =150
    BL      DELAY_MS
    LDR     R0, =GPIOB_ODR
    MOV     R1, #YELLOW
    STR     R1, [R0]
    LDR     R0, =150
    BL      DELAY_MS
    SUBS    R4, R4, #1
    BNE     WS_LP
    LDR     R0, =GPIOB_ODR
    MOV     R1, #0
    STR     R1, [R0]                ; All LEDs off after animation
    POP     {R4, PC}


; -----------------------------------------------------------
; SUBROUTINE: PULSE_WAIT
; Creates a "breathing" LED effect using software PWM:
; all three LEDs smoothly fade in and out in a loop.
; The routine exits as soon as the player presses the button.
;
; How it works: each PWM cycle, the LEDs are on for a time
; proportional to brightness (R4) and off for the remainder.
; R4 counts 0->100->0 repeatedly. R5 tracks direction (up/down).
; INPUT/OUTPUT: None. Exits when button (PB13) is pressed.
; -----------------------------------------------------------
PULSE_WAIT
    PUSH    {R4-R7, LR}
    MOV     R4, #0                  ; R4 = brightness level (0 to 100)
    MOV     R5, #1                  ; R5 = direction: 1=brightening, 0=dimming

PW_LOOP
    ; Check button at the top of every PWM cycle
    LDR     R0, =GPIOB_IDR
    LDR     R1, [R0]
    TST     R1, #BTN                ; Is button pressed (PB13 = LOW)?
    BEQ     PW_EXIT                 ; Yes -> exit breathing loop

    ; ON phase: LEDs on for (brightness * 128) loop iterations
    LDR     R0, =GPIOB_ODR
    MOV     R1, #ALL_LEDS
    STR     R1, [R0]
    MOV     R6, R4
    LSL     R6, R6, #7              ; Multiply brightness by 128 for visible timing
PW_ON_D
    CMP     R6, #0
    BEQ     PW_OFF
    SUBS    R6, R6, #1
    BNE     PW_ON_D

    ; OFF phase: LEDs off for ((100-brightness) * 128) iterations
PW_OFF
    LDR     R0, =GPIOB_ODR
    MOV     R1, #0
    STR     R1, [R0]
    RSB     R6, R4, #100            ; R6 = 100 - brightness
    LSL     R6, R6, #7
PW_OFF_D
    CMP     R6, #0
    BEQ     PW_UPD
    SUBS    R6, R6, #1
    BNE     PW_OFF_D

    ; Update brightness: increment or decrement, flip direction at limits
PW_UPD
    CMP     R5, #1
    BNE     PW_DOWN
PW_UP
    ADD     R4, R4, #1
    CMP     R4, #100                ; Reached maximum brightness?
    BNE     PW_LOOP
    MOV     R5, #0                  ; Switch to dimming
    B       PW_LOOP
PW_DOWN
    SUBS    R4, R4, #1
    CMP     R4, #0                  ; Reached minimum brightness?
    BNE     PW_LOOP
    MOV     R5, #1                  ; Switch to brightening
    B       PW_LOOP
PW_EXIT
    LDR     R0, =GPIOB_ODR
    MOV     R1, #0
    STR     R1, [R0]                ; LEDs off before returning
    POP     {R4-R7, PC}


; -----------------------------------------------------------
; SUBROUTINE: DELAY_CHECK_BTN
; Waits for a given number of milliseconds, but returns
; immediately with a flag if the button is pressed early.
; This is used during the red/yellow/fake-out phases to
; detect false starts without missing any button presses.
; INPUT:  R0 = number of milliseconds to wait
; OUTPUT: R0 = 0 if time expired normally (no press)
;         R0 = 1 if button was pressed before time expired
; -----------------------------------------------------------
DELAY_CHECK_BTN
    PUSH    {R4, LR}
    CMP     R0, #0
    BEQ     DCB_NO                  ; Zero delay -> return 0 immediately
    MOV     R4, R0                  ; R4 = millisecond countdown
DCB_LUP
    LDR     R2, =STK_CTRL
DCB_TK
    ; Check button every iteration for fastest response
    LDR     R0, =GPIOB_IDR
    LDR     R1, [R0]
    TST     R1, #BTN                ; Button pressed? (LOW = active low)
    BEQ     DCB_YES                 ; Pressed -> return 1 (false start)
    ; Check if 1 ms SysTick tick has elapsed (COUNTFLAG = bit 16)
    LDR     R1, [R2]
    TST     R1, #(1<<16)            ; COUNTFLAG is set every 1 ms, clears on read
    BEQ     DCB_TK                  ; Not yet -> keep polling
    SUBS    R4, R4, #1              ; 1 ms elapsed -> subtract from countdown
    BNE     DCB_LUP                 ; More time remaining -> loop
DCB_NO
    MOV     R0, #0                  ; Time expired, no false start
    POP     {R4, PC}
DCB_YES
    MOV     R0, #1                  ; Button pressed early
    POP     {R4, PC}


; -----------------------------------------------------------
; SUBROUTINE: LCD_INIT
; Sends the HD44780 LCD power-on initialization sequence.
; This 3-step function-set sequence is required by the
; datasheet before any other commands can be sent.
; Sets 8-bit mode, 2 display lines, cursor off.
; INPUT/OUTPUT: None
; -----------------------------------------------------------
LCD_INIT
    PUSH    {LR}
    LDR     R0, =150
    BL      DELAY_MS                ; Wait >40 ms after power-on before first command
    MOV     R0, #0x30               ; Function set command -- must be sent 3 times
    BL      LCD_CMD
    LDR     R0, =10
    BL      DELAY_MS                ; Wait >4.1 ms after first send
    MOV     R0, #0x30
    BL      LCD_CMD
    LDR     R0, =1
    BL      DELAY_MS                ; Wait >100 us after second send
    MOV     R0, #0x30
    BL      LCD_CMD
    MOV     R0, #0x38               ; 0x38: 8-bit bus, 2 lines, 5x8 dot font
    BL      LCD_CMD
    MOV     R0, #0x0C               ; 0x0C: display on, cursor off, no blink
    BL      LCD_CMD
    BL      LCD_CLEAR
    POP     {PC}


; -----------------------------------------------------------
; SUBROUTINE: LCD_CMD
; Sends a command byte to the LCD (RS pin = 0 means command).
; INPUT:  R0 = command byte
; -----------------------------------------------------------
LCD_CMD
    PUSH    {LR}
    LDR     R1, =GPIOA_ODR
    MOV     R2, #0                  ; RS=0 and RW=0: command mode
    STR     R2, [R1]
    LDR     R1, =GPIOC_ODR
    STR     R0, [R1]                ; Put command on 8-bit data bus (PC0-PC7)
    BL      LCD_PULSE               ; Toggle EN to latch the byte into LCD
    POP     {PC}


; -----------------------------------------------------------
; SUBROUTINE: LCD_DATA
; Sends a character byte to the LCD (RS pin = 1 means data).
; INPUT:  R0 = ASCII character code to display
; -----------------------------------------------------------
LCD_DATA
    PUSH    {LR}
    LDR     R1, =GPIOA_ODR
    MOV     R2, #RS                 ; RS=1: data register selected
    STR     R2, [R1]
    LDR     R1, =GPIOC_ODR
    STR     R0, [R1]                ; Put character on data bus
    BL      LCD_PULSE
    POP     {PC}


; -----------------------------------------------------------
; SUBROUTINE: LCD_PULSE
; Generates the Enable (EN) high-then-low pulse that causes
; the LCD to latch whatever is currently on the data bus.
; A busy-wait loop provides the required pulse timing.
; INPUT/OUTPUT: None
; -----------------------------------------------------------
LCD_PULSE
    LDR     R1, =GPIOA_ODR
    LDR     R2, [R1]
    ORR     R2, R2, #EN             ; Drive EN pin HIGH
    STR     R2, [R1]
    LDR     R3, =30000              ; Busy-wait to satisfy EN pulse width timing
LP1 SUBS    R3, R3, #1
    BNE     LP1
    BIC     R2, R2, #EN             ; Drive EN pin LOW (LCD latches data here)
    STR     R2, [R1]
    LDR     R3, =30000              ; Busy-wait for EN recovery time
LP2 SUBS    R3, R3, #1
    BNE     LP2
    BX      LR


; -----------------------------------------------------------
; SUBROUTINE: LCD_CLEAR
; Sends the clear-display command (0x01) and waits 20 ms
; for the LCD controller to finish clearing its memory.
; -----------------------------------------------------------
LCD_CLEAR
    PUSH    {LR}
    MOV     R0, #0x01               ; Clear display command
    BL      LCD_CMD
    LDR     R0, =20                 ; HD44780 needs up to 1.52 ms; we wait 20 ms
    BL      DELAY_MS
    POP     {PC}


; -----------------------------------------------------------
; SUBROUTINE: LCD_PRINT_STR
; Prints a null-terminated ASCII string to the LCD starting
; at the current cursor position. Loops through each byte
; and sends it to LCD_DATA until the null terminator (0) is found.
; INPUT:  R0 = memory address of the string
; -----------------------------------------------------------
LCD_PRINT_STR
    PUSH    {R4, LR}
    MOV     R4, R0                  ; R4 = pointer that walks through the string
LSTR_LP
    LDRB    R0, [R4], #1            ; Load one byte and advance pointer
    CMP     R0, #0                  ; Null terminator?
    BEQ     LSTR_EX                 ; Yes -> done
    BL      LCD_DATA                ; No -> send character to LCD
    B       LSTR_LP
LSTR_EX
    POP     {R4, PC}


; -----------------------------------------------------------
; SUBROUTINE: LCD_PRINT_NUM
; Converts an unsigned integer (0-9999) to decimal digits
; and prints each digit to the LCD. Leading zeros are
; suppressed (e.g. 42 prints as "42" not "0042").
;
; Algorithm: repeatedly divide by 1000, 100, 10, 1 using
; UDIV to extract each digit, then MLS to remove it.
; Each digit is converted to ASCII by adding 48 (ASCII '0').
; INPUT:  R0 = unsigned integer value to print (0-9999)
; -----------------------------------------------------------
LCD_PRINT_NUM
    PUSH    {R4-R7, LR}
    MOV     R4, R0                  ; R4 = value remaining to print
    LDR     R5, =1000               ; R5 = current divisor (1000 -> 100 -> 10 -> 1)
    MOV     R7, #0                  ; R7 = flag: 0=still suppressing leading zeros
D_LUP
    UDIV    R6, R4, R5              ; R6 = current digit
    CMP     R6, #0
    BNE     P_DI                    ; Non-zero digit -> always print it
    CMP     R7, #1
    BEQ     P_DI                    ; A non-zero digit was seen before -> print zero
    CMP     R5, #1
    BEQ     P_DI                    ; Units place -> always print (even if 0)
    B       N_DI                    ; Leading zero -> skip it
P_DI
    MOV     R7, #1                  ; Mark that we have printed a significant digit
    ADD     R0, R6, #48             ; Add 48 to convert digit to ASCII character
    BL      LCD_DATA                ; Send ASCII digit to LCD
N_DI
    MLS     R4, R6, R5, R4         ; Remove printed digit: R4 = R4 - (digit * divisor)
    LDR     R1, =10
    UDIV    R5, R5, R1              ; Move to next lower divisor
    CMP     R5, #0
    BNE     D_LUP                   ; Divisor not yet zero -> process next digit
    POP     {R4-R7, PC}


; -----------------------------------------------------------
; SUBROUTINE: DELAY_MS
; Blocks for exactly R0 milliseconds by counting SysTick
; COUNTFLAG events. The SysTick timer is configured to set
; COUNTFLAG (bit 16 of STK_CTRL) exactly once per millisecond.
; Reading STK_CTRL automatically clears COUNTFLAG.
; INPUT:  R0 = number of milliseconds to wait
; -----------------------------------------------------------
DELAY_MS
    PUSH    {R4, LR}
    MOV     R4, R0                  ; R4 = countdown (ms remaining)
MS_LUP
    LDR     R2, =STK_CTRL
W_TICK
    LDR     R1, [R2]
    TST     R1, #(1<<16)            ; Test COUNTFLAG -- set once every 1 ms
    BEQ     W_TICK                  ; Not set yet -> keep waiting
    SUBS    R4, R4, #1              ; One ms elapsed -> decrement counter
    BNE     MS_LUP                  ; More ms remaining -> loop
    POP     {R4, PC}


; -----------------------------------------------------------
; SUBROUTINE: GET_RANDOM
; Generates a pseudo-random number using a 16-bit Galois LFSR
; (Linear Feedback Shift Register). The state is shifted one
; step each call, producing a sequence of 65535 unique values
; before repeating. The feedback bit is computed by XORing
; specific tap positions of the current state.
; INPUT:  None (reads LFSR_STATE from RAM)
; OUTPUT: R0 = next pseudo-random 16-bit value
; -----------------------------------------------------------
GET_RANDOM
    LDR     R0, =LFSR_STATE
    LDR     R1, [R0]                ; R1 = current LFSR state
    MOV     R2, R1
    ; XOR specific bit positions together to produce a feedback bit.
    ; These tap positions correspond to a maximal-length polynomial.
    EOR     R2, R2, R1, LSR #2
    EOR     R2, R2, R1, LSR #3
    EOR     R2, R2, R1, LSR #5
    AND     R2, R2, #1              ; Isolate the single feedback bit (0 or 1)
    LSL     R2, R2, #15             ; Shift feedback bit to the MSB position
    LSR     R1, R1, #1              ; Shift entire state right by 1
    ORR     R1, R1, R2              ; Insert feedback bit into MSB
    STR     R1, [R0]                ; Save updated state back to RAM
    MOV     R0, R1                  ; Return new state as the random value
    BX      LR


; ==========================================================
; LITERAL POOL 3 & STRING TABLE
; Null-terminated strings for LCD display.
; Each string is padded to 16 characters to fill the LCD line.
; ==========================================================
    LTORG

MSG_WELC1       DCB     "   WELCOME TO   ",0
MSG_WELC2       DCB     "  QUICK CLICK!  ",0
MSG_MOD1        DCB     " CLICK = NORMAL ",0
MSG_MOD2        DCB     " HOLD 1s = HARD ",0
MSG_MNOR1       DCB     "  NORMAL MODE   ",0
MSG_MNOR2       DCB     "    SELECTED    ",0
MSG_MHRD1       DCB     " HARDCORE MODE  ",0
MSG_MHRD2       DCB     "    SELECTED    ",0
MSG_START       DCB     "  PRESS START   ",0
MSG_RDY         DCB     "  GET READY...  ",0
MSG_RED         DCB     "    READY...    ",0
MSG_YEL         DCB     "     SET...     ",0
MSG_FAK         DCB     "   STEADY...    ",0
MSG_GRN         DCB     "     GO!!!      ",0
MSG_FALSE       DCB     "   TOO EARLY!   ",0
MSG_TIME        DCB     "   YOUR TIME:   ",0
MSG_BEST        DCB     "   BEST TIME:   ",0
MSG_NEW         DCB     "  NEW RECORD!   ",0
MSG_PAD         DCB     "     ",0            ; 5-space padding to centre numbers
MSG_MS          DCB     "ms        ",0
RANK_BOT        DCB     "   RANK: BOT!   ",0
RANK_PRO        DCB     "   RANK: PRO!   ",0
RANK_GOOD       DCB     "   RANK: GOOD   ",0
RANK_SLOW       DCB     " RANK: TOO SLOW ",0

    ALIGN
    END
