; RUN: opt -disable-output -force-vector-width=0 %s
; RUN: opt -disable-output -force-vector-width=3 %s
; RUN: opt -disable-output -force-vector-width=0x8 %s
; RUN: opt -disable-output -force-vector-width=fission:1 %s
; RUN: opt -disable-output -force-vector-width=fission:8 %s
; RUN: not opt -disable-output -force-vector-width=fission:0 %s 2>&1 | FileCheck %s --check-prefix=WIDTH
; RUN: not opt -disable-output -force-vector-width=fission:3 %s 2>&1 | FileCheck %s --check-prefix=WIDTH
; RUN: not opt -disable-output -force-vector-width=fission:128 %s 2>&1 | FileCheck %s --check-prefix=WIDTH
; RUN: not opt -disable-output -force-vector-width=fission:abc %s 2>&1 | FileCheck %s --check-prefix=NUMBER

; Numeric arguments continue to use the existing unsigned parser, including
; zero, non-power-of-two values, and hexadecimal notation. Candidate syntax
; additionally validates the known-minimum map width. Width 1 is useful for a
; scalable map and is diagnosed as ineligible if used for a fixed scalar map.
; WIDTH: fission width must be a nonzero power of two no greater than 64
; NUMBER: 'abc' value invalid for uint argument!
