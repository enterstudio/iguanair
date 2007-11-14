; **************************************************************************
; * ir.asm *****************************************************************
; **************************************************************************
; *
; * IR transceiver functions
; *
; * Copyright (C) 2007, IguanaWorks Incorporated (http://iguanaworks.net)
; * Original Author: Brian Shucker <brian@iguanaworks.net>
; * Maintainer: Joseph Dunn <jdunn@iguanaworks.net>
; *
; * Distributed under the GPL version 2.
; * See LICENSE for license details.
; */


include "m8c.inc"       ; part specific constants and macros
include "memory.inc"    ; Constants & macros for SMM/LMM and Compiler
include "loader.inc"
include "body.inc"

; exported functions
export rx_disable
export rx_reset
export transmit_code
export tcap_int
export twrap_int
export write_signal

; exported variables
export rx_on
export rx_fill
export buf_size

AREA bss
;;; transmission variables
tx_pins:
    BLK 1 ; pins to use for current tx
tx_state:
    BLK 1 ; state of tx (on or off)
tx_temp:
    BLK 1 ; tx temp variable

;;; reception variables
rx_on:
    BLK 1 ; is the receiver on?
rx_overflow:
    BLK 1 ; mark when receive overflows
rx_fill:
    BLK 1 ; mark when we have PACKET_SIZE bytes because there is no jgt
buf_size:
    BLK 1 ; number of bytes in buffer (or waste one for cicular buffer)
read_ptr:
    BLK 1 ; where to read data from in the circular buffer

;;; temporary variables used in interrupt handlers
rx_high:
    BLK 1 ; received data high byte
rx_low:
    BLK 1 ; received data low byte
rx_pulse:
    BLK 1 ; high bit is 1 if this is a pulse, 0 for space

AREA text
; FUNCTION: get_byte
;   puts the next byte off the rx buffer into A
get_byte:
    mvi A, [read_ptr]                    ; read byte, increment ptr
    cmp [read_ptr], buffer + BUFFER_SIZE ; check for end of buffer
    jnz gb_dec
    mov [read_ptr], buffer ; wrap around to start of buffer

  gb_dec:
    ; we want to decrement buffer atomically
    and F, 0xFE ; clear global interrupt bit

    ; decrement carefully
    dec [buf_size]
    ; if we no longer have a full packet worth of data, clear rx_fill flag
    cmp [buf_size], PACKET_SIZE - 1
    jnz gb_decdone
    mov [rx_fill], 0

  gb_decdone:
    or  F, 0x1 ; re-enable global interrupts
    ret

; FUNCTION: put_byte
; puts value into the circular buffer
;   pre: A is value to load
; does not modify A
put_byte:
    cmp [buf_size], BUFFER_SIZE ; check for overflow
    jz pb_oflow                 ; jmp handle overflow
    mvi [buffer_ptr], A         ; load the data
    inc [buf_size]              ; increment the data count
    cmp [buf_size], PACKET_SIZE ; see if we have enough data to send to host
    jnz pb_check_wrap           ; we don't, do nothing to the flag
    mov [rx_fill], 1            ; we do, set fill flag to true

  pb_check_wrap:
    cmp [buffer_ptr], buffer + BUFFER_SIZE ; check for end of buffer
    jnz pb_done                            ; done if we didn't hit the end
    mov [buffer_ptr], buffer               ; wrap around to start of buffer
    jmp pb_done

  pb_oflow:
    ; set the rx overflow flag, clear buffers
    mov [rx_overflow], 1     ; set the overflow flag
    mov [read_ptr], buffer   ; reset read ptr to start of buffer
    mov [buffer_ptr], buffer ; reset rx ptr to start of buffer
    mov [buf_size], 0        ; reset size to 0

  pb_done:
    ret

; FUNCTION: write_signal
;   writes one packet's worth of signal data from the rx buffer to host
write_signal:
    ; see if there is data ready
    cmp [rx_fill], 0
    jz ws_done

    ; we use the control packet buffer to send the data
    mov X, PACKET_SIZE - 1  ; bytes to copy (last is fill)
    mov [tmp1], control_pkt ; packet pointer
  ws_ld_loop:
    lcall get_byte          ; get next byte
    mvi [tmp1], A
    dec X
    jnz ws_ld_loop

    ; put buffer fill level in last byte
    mov A, [buf_size]
    mvi [tmp1], A

    ; send the data packet
    mov X, PACKET_SIZE ; packet size
    mov A, control_pkt ; packet pointer
    lcall write_packet ; send the data
  ws_done:
    ret

; FUNCTION rx_disable disables the IR receiver
rx_disable:
    ; disable the timer interrupt
    mov A, REG[INT_MSK1]
    and A, ~0b10000000   ; tcap interrupt enable
    mov REG[INT_MSK1], A

    ; disable the timer wrap interrupt
    mov A, REG[INT_MSK2]
    and A, ~0b00000010   ; twrap interrupt enable
    mov REG[INT_MSK2], A

    ; make sure the active LOW transmit LEDs are OFF
    ; does this device support channels?
    call get_feature_list
    and A, HAS_LEDS | HAS_BOTH | HAS_SOCKETS
    call rx_pins_off
    ret

; FUNCTION: rx_reset enables the IR receiver
rx_reset:
    ; reset a pile of variables related to reception
    mov [rx_overflow], 0     ; clear overflow flag
    mov [rx_fill], 0         ; clear fill flag
    mov [read_ptr], buffer   ; reset write ptr to start of buffer
    mov [buffer_ptr], buffer ; reset rx ptr to start of buffer
    mov [buf_size], 0        ; reset size to 0

    mov A, [rx_on] ; check if rx should be enabled
    jz rx_disable  ; disable if necessary

    ; enable the timer capture interrupt
    mov A, REG[INT_MSK1]
    or A, 0b10000000     ; tcap interrupt enable
    mov REG[INT_MSK1], A

    ; enable the timer wrap interrupt
    mov A, REG[INT_MSK2]
    or A, 0b00000010     ; twrap interrupt enable
    mov REG[INT_MSK2], A

  rx_reset_done:
    ret

rx_pins_off:
    jnz rx_disable_tx
    ; old --> active high --> and ~
    and REG[OLD_TX_BANK], ~OLD_TX_MASK
    jmp rx_disable_done
  rx_disable_tx:
    ; new --> active low --> or
    or REG[TX_BANK], TX_MASK
    jmp rx_disable_done
  rx_disable_done:
    ret

; FUNCTION load_value
; loads a received value into the data buffer
;  pre: rx_high and rx_low have the raw timer data
;       rx_pulse has the pulse bit set correctly
; returns: 1 if ok, 0 if overflow
load_value:
    push X
    ; shift right 6 bits
    mov A, [rx_low]
    asr A
    asr A
    asr A
    asr A
    asr A
    asr A
    ; clear the upper 6 bits (because of sign extension mask off upper bits)
    and A, 0x03
    mov [rx_low], A ; stores bits 0-1 of final result

    ; for bits 2-6, we want to use bits 0-4 of the upper byte, so shift left 2
    mov A, [rx_high]
    asl A
    asl A
    or [rx_low], A ; stores bits 2-6 of final result
    jz ld_skip_dec ; if zero, don't decrement
    ;NOTE: this gives us some minor inaccuracy
    ;decrement raw value by one, so our range is 1-128 instead of 0-127
    dec [rx_low]
  ld_skip_dec:
    ;last bit of final result is the pulse bit
    mov A, [rx_low]
    and A, 0x7F ;clear pulse bit in case it's already set
    or  A, [rx_pulse]
    mov [rx_low], A

    ;now we need to deal with long pulses: send repeated FF packets to
    ;take care of times longer than 128

    ;we need to loop for the value of bits 5-7 of the high byte
    mov A, [rx_high]
    ;shift 5 bits over
    asr A
    asr A
    asr A
    asr A
    asr A
    ;clear the upper 5 bits (because of sign extend, have to be sure they're 0)
    and A, 0x7

    ;set up the loop
    mov X, A ;loop counter in X
    jz ld_big_done ;if zero, we don't need to do any big loads

    ;put the value to load in A
    mov A,[rx_pulse] ;set pulse bit correctly
    or A, 0x7F; load max value

    ;loop and load the right number of max value packets
  ld_big_loop:
    lcall put_byte ;load A into buffer
    dec X
    jnz ld_big_loop

  ld_big_done:
    ;send the remainder
    mov A, [rx_low] ;get the remainder byte
    lcall put_byte ;load A into buffer
    pop X
    ret



; INTERRUPT: timer/capture interrupt handler
tcap_int:
    PUSH A

    ; read the timer in temporary variables
    mov A, REG[FRTMRL] ; load low-order byte
    mov [rx_low], A    ; store
    mov A, REG[FRTMRH] ; load high-order byte
    mov [rx_high], A   ; store

    ; check if we have a rising or falling edge
    mov A, REG[TCAPINTS] ; read capture interrupt status
    and A, 0x1           ; true if  this is a rising edge
    jnz tcapi_rise

  ; if here, it's a falling edge
  tcap_rx_fall:
    mov [rx_pulse], 0x80 ; set pulse bit to indicate space
    jmp tcapi_done

  ; found a rising edge
  tcapi_rise:
    mov [rx_pulse], 0  ; clear pulse bit to indicate pulse
    jmp tcapi_done

  tcapi_done:
    lcall load_value        ; store into data buffer
    mov REG[FRTMRL], 0      ; reset timer low byte
    mov REG[FRTMRH], 0      ; reset timer high byte
    mov REG[TCAPINTS], 0x0F ; clear int status

    POP A
    reti ; done

; INTERRUPT: timer wrap interrupt handler
twrap_int:
    push A

    ; load an 0x80 to indicate full-length space
    mov A, 0x80
    lcall put_byte

    pop A
    reti ; done

; FUNCTION: transmit_code
; transmit the code over IR
; code format: first bit is 1 for on, 0 for off
; next 7 bits are length in 26.3uS (38KHz) increments--that's 316 clocks up, 316 down at 24MHz
transmit_code:
    ; does this device support channels?
    mov X, OLD_TX_BANK
    mov [tx_pins], OLD_TX_MASK
    call get_feature_list
    and A, HAS_LEDS | HAS_BOTH | HAS_SOCKETS
    mov [tmp3], A
    jz tx_start

    ; read a byte describing channel selection, and make sure it only
    ; specifies valid channels
    mov X, TX_BANK
    and [control_pkt + CDATA + 1], TX_MASK
    mov [tx_pins], [control_pkt + CDATA + 1]
    ; if the byte was 0 then transmit on all channels
    mov A, [tx_pins]
    jnz tx_start
    mov [tx_pins], TX_MASK
  tx_start:
    mov [buffer_ptr], buffer          ; reset to start of buffer
    mov [tx_state], 0                 ; clear tx state
    mov [tmp1], [control_pkt + CDATA] ; get number of bytes to transmit
    mov A, [tmp1]                     ; set zero flag if tmp1 is zero
    jz tx_end_pulse                   ; if zero byte, we're done

  tx_loop:
    mvi A, [buffer_ptr] ; move buffer data into A, increment pointer
    mov [tx_temp], A    ; store byte
    and A, 0x7F         ; mask off the pulse length bits
    asl A               ; shift left to multiply by two due to carrier division
    mov [tmp2], A       ; store pulse length in tmp2

    mov A, [tx_temp]  ; get original byte back
    and A, 0x80       ; mask off pulse on/off bit
    jz tx_on          ; if on, jump to tx_on, else fall through
    mov [tx_state], 0 ; clear tx
    jmp tx_pulse      ; start sending pulse

  tx_on:
    mov [tx_state], [tx_pins] ; mask on tx bits
    jmp tx_pulse              ; start sending pulse--this jump seems redundant,
                        ; but is there to make timing the same on both branches

  tx_pulse: ; ready to send a pulse.  Need to AND in a XX kHz carrier
    mov A, [tmp2]       ; put pulse length into A. zero flag valid   [5 cycles]
    jz tx_end_pulse     ; this pulse is done                         [5 cycles]
    mov A, REG[X]       ; get current register state                 [7 cycles]
    xor A, [tx_state]   ; if on, toggle, else doing nothing          [6 cycles]
    mov REG[X], A       ; write change to register                   [6 cycles]
    dec [tmp2]          ; decrement remaining pulse length           [7 cycles]

;this is a set of 7-clock delays.  You jump into it at different points in
;order to get different length delays.
    ; load the bytes to skip for 4 delays
    mov A, [control_pkt + CDATA + 2] ; load the 7s delay             [5 cycles]
    ; A + argument + (PC + 1) = A + 1 + PC + 1 = A + PC + 2 = cmp
    jacc delay_7s                    ; jump to the precise offset    [7 cycles]

    ; 7 cmps for a possible delay of 7 * 7 = 49 cycles
  delay_7s:
    cmp A, [0]
    cmp A, [0]
    cmp A, [0]
    cmp A, [0]

;this is a set of 4-clock delays.  You jump into it at different points in
;order to get different length delays.
    ; load the bytes to skip for 4 delays
    mov A, [control_pkt + CDATA + 3] ; load the 4s delay             [5 cycles]
    ; A + argument + (PC + 1) = A + 1 + PC + 1 = A + PC + 2 = nop
    jacc delay_4s                    ; jump to the precise offset    [7 cycles]

    ; 100 nops for a possible delay of 4 * 100 = 400 cycles
  delay_4s:
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop

    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop

    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop

    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop

    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop

    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop

    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop

    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop

    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop

    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop

    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop

    jmp tx_pulse ; continue the pulse                                [5 cycles]

  ; end of the transmit function
  tx_end_pulse:
    mov A, [tmp3] ; make sure tx pins are off
    call rx_pins_off
    dec [tmp1]    ; decrement remaining byte count
    jnz tx_loop   ; if more, go to next pulse
    ret           ; done
