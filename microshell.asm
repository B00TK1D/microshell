# microshell: an extremely small POSIX-ish shell for x86_64 Linux.
#
# It is assembled as a flat, position-independent blob: no ELF headers, no
# dynamic linking, no libc.  Everything (code and strings) lives in .text and
# is addressed RIP-relative, so the blob can be mapped anywhere and called.
#
# Behaviour:
#   * reads lines from stdin
#   * splits them into words, honouring '...' , "..." and backslash escapes
#   * supports several ';'-separated commands per line and '#' comments
#   * searches PATH for the program and execs it (fork + execve + wait4)
#   * builtins: exit [status], cd [dir]
#   * on EOF returns to the caller

.intel_syntax noprefix
.text

# Stack frame layout (r15 points at its base).
.equ FRAME,   24576
.equ LINE,    0          # 4096-byte line buffer
.equ PATHBUF, 4096       # 512-byte scratch for $dir/$cmd
.equ ARGV,    4608       # 2048 pointers (max tokens in one line)
.equ STATUS,  20992      # wait status

.global shell_start
shell_start:
        push    rbx
        push    rbp
        push    r12
        push    r13
        push    r14
        push    r15
        sub     rsp, FRAME
        mov     r15, rsp

# ---------------------------------------------------------------------------
# Read one line, one byte at a time.  r14 = saw EOF, r12 = line length.
# ---------------------------------------------------------------------------
main_loop:
        xor     r14d, r14d
        xor     r12d, r12d
read_char:
        lea     rsi, [r15 + LINE]
        add     rsi, r12
        xor     eax, eax                # SYS_read
        xor     edi, edi                # fd 0
        mov     edx, 1
        syscall
        test    rax, rax
        js      read_error
        jz      read_eof
        lea     rsi, [r15 + LINE]
        add     rsi, r12
        cmp     byte ptr [rsi], 10      # '\n'
        je      line_done
        inc     r12
        cmp     r12, 4094
        jb      read_char
        jmp     line_done               # buffer full, force a line

read_error:
        cmp     rax, -4                 # EINTR: just retry
        je      read_char
read_eof:
        mov     r14d, 1
line_done:
        lea     rsi, [r15 + LINE]
        add     rsi, r12
        mov     byte ptr [rsi], 0
        test    r12, r12
        jz      after_line

# ---------------------------------------------------------------------------
# Tokenise the line in place into argv[].  r13 = read ptr, rbp = write ptr,
# rbx = argv base, r12 = argc.
# ---------------------------------------------------------------------------
        lea     r13, [r15 + LINE]
        lea     rbx, [r15 + ARGV]
        lea     rbp, [r15 + LINE]
        xor     r12d, r12d
tok_skip:
        mov     al, [r13]
        test    al, al
        jz      tok_done
        cmp     al, ' '
        je      tok_skip_one
        cmp     al, 9
        je      tok_skip_one
        cmp     al, 13
        je      tok_skip_one
        cmp     al, 10
        je      tok_skip_one
        cmp     al, 59                  # ';'
        je      tok_skip_one
        jmp     tok_start
tok_skip_one:
        inc     r13
        jmp     tok_skip
tok_start:
        cmp     byte ptr [r13], 35      # '#'
        je      tok_comment
        cmp     r12, 2047               # argv[] holds 2048 pointers
        jae     tok_comment_loop
        mov     [rbx + r12*8], rbp
        inc     r12
tok_copy:
        mov     al, [r13]
        test    al, al
        jz      tok_finish_line
        cmp     al, ' '
        je      tok_finish_tok
        cmp     al, 9
        je      tok_finish_tok
        cmp     al, 13
        je      tok_finish_tok
        cmp     al, 10
        je      tok_finish_tok
        cmp     al, 59                  # ';'
        je      tok_finish_semi
        cmp     al, 34                  # '"'
        je      tok_dq
        cmp     al, 39                  # '\''
        je      tok_sq
        cmp     al, 92                  # '\\'
        je      tok_bs
        mov     [rbp], al
        inc     rbp
        inc     r13
        jmp     tok_copy
tok_bs:
        inc     r13
        mov     al, [r13]
        test    al, al
        jz      tok_finish_line
        mov     [rbp], al
        inc     rbp
        inc     r13
        jmp     tok_copy
tok_dq:
        inc     r13
tok_dq_loop:
        mov     al, [r13]
        test    al, al
        jz      tok_finish_line
        cmp     al, 34
        je      tok_dq_close
        mov     [rbp], al
        inc     rbp
        inc     r13
        jmp     tok_dq_loop
tok_dq_close:
        inc     r13
        jmp     tok_copy
tok_sq:
        inc     r13
tok_sq_loop:
        mov     al, [r13]
        test    al, al
        jz      tok_finish_line
        cmp     al, 39
        je      tok_sq_close
        mov     [rbp], al
        inc     rbp
        inc     r13
        jmp     tok_sq_loop
tok_sq_close:
        inc     r13
        jmp     tok_copy
tok_finish_tok:
        mov     byte ptr [rbp], 0
        inc     rbp
        inc     r13
        jmp     tok_skip
tok_finish_semi:
        mov     byte ptr [rbp], 0
        inc     rbp
        inc     r13
        jmp     tok_done
tok_comment:
        inc     r13
tok_comment_loop:
        cmp     byte ptr [r13], 0
        je      tok_finish_line
        inc     r13
        jmp     tok_comment_loop
tok_finish_line:
        mov     byte ptr [rbp], 0
tok_done:
        mov     qword ptr [rbx + r12*8], 0
        test    r12, r12
        jz      tok_more
        call    run_command
tok_more:
        mov     al, [r13]
        test    al, al
        jz      after_line
        xor     r12d, r12d
        jmp     tok_skip

after_line:
        test    r14d, r14d
        jnz     shell_return
        jmp     main_loop

# ---------------------------------------------------------------------------
# run_command: execute the argv[] just built.  Returns to the tokeniser, or
# does not return for `exit` / a successful exec / a failed child.
# ---------------------------------------------------------------------------
run_command:
        mov     rdi, [r15 + ARGV]
        lea     rsi, [rip + str_exit]
        call    str_eq
        test    eax, eax
        jnz     builtin_exit

        mov     rdi, [r15 + ARGV]
        lea     rsi, [rip + str_cd]
        call    str_eq
        test    eax, eax
        jnz     builtin_cd

        mov     eax, 57                 # SYS_fork
        syscall
        test    rax, rax
        js      run_ret
        jnz     parent_wait

# --- child ---------------------------------------------------------------
        mov     rdi, [r15 + ARGV]
        mov     rsi, rdi
scan_slash:
        mov     al, [rsi]
        test    al, al
        jz      search_path
        cmp     al, 47                  # '/'
        je      exec_direct
        inc     rsi
        jmp     scan_slash

exec_direct:
        lea     rsi, [r15 + ARGV]
        xor     edx, edx
        mov     eax, 59                 # SYS_execve
        syscall
        jmp     not_found

search_path:
        lea     r13, [rip + path_dirs]
next_dir:
        mov     al, [r13]
        test    al, al
        jz      not_found
        lea     rdi, [r15 + PATHBUF]
        lea     r8, [r15 + PATHBUF + 500]
        mov     rsi, r13
copy_dir:
        mov     al, [rsi]
        test    al, al
        jz      dir_end
        cmp     rdi, r8
        jae     dir_end
        mov     [rdi], al
        inc     rdi
        inc     rsi
        jmp     copy_dir
dir_end:
        mov     r13, rsi
        inc     r13
        mov     byte ptr [rdi], 47      # '/'
        inc     rdi
        lea     r8, [r15 + PATHBUF + 508]
        mov     rsi, [r15 + ARGV]
copy_cmd:
        mov     al, [rsi]
        test    al, al
        jz      cmd_end
        cmp     rdi, r8
        jae     cmd_end
        mov     [rdi], al
        inc     rdi
        inc     rsi
        jmp     copy_cmd
cmd_end:
        mov     byte ptr [rdi], 0
        lea     rdi, [r15 + PATHBUF]
        lea     rsi, [r15 + ARGV]
        xor     edx, edx
        mov     eax, 59                 # SYS_execve
        syscall
        jmp     next_dir

not_found:
        mov     eax, 1                  # SYS_write
        mov     edi, 2
        lea     rsi, [rip + msg_not_found]
        mov     edx, 30
        syscall
        mov     eax, 60                 # SYS_exit
        mov     edi, 127
        syscall

# --- parent --------------------------------------------------------------
parent_wait:
        mov     rdi, rax
parent_wait_retry:
        lea     rsi, [r15 + STATUS]
        xor     edx, edx
        xor     r10d, r10d
        mov     eax, 61                 # SYS_wait4
        syscall
        cmp     rax, -4                 # EINTR: wait again
        je      parent_wait_retry
run_ret:
        ret

# ---------------------------------------------------------------------------
# Builtin implementations.
# ---------------------------------------------------------------------------
builtin_exit:
        mov     rdi, [r15 + ARGV + 8]
        test    rdi, rdi
        jz      exit_zero
        xor     eax, eax
atoi_loop:
        movzx   ecx, byte ptr [rdi]
        test    cl, cl
        jz      atoi_done
        sub     ecx, '0'
        cmp     ecx, 9
        ja      atoi_done
        imul    eax, eax, 10
        add     eax, ecx
        inc     rdi
        jmp     atoi_loop
atoi_done:
        mov     edi, eax
        jmp     do_exit
exit_zero:
        xor     edi, edi
do_exit:
        mov     eax, 60                 # SYS_exit
        syscall

builtin_cd:
        mov     rdi, [r15 + ARGV + 8]
        test    rdi, rdi
        jnz     cd_have_arg
        lea     rdi, [rip + str_slash]
cd_have_arg:
        mov     eax, 80                 # SYS_chdir
        syscall
        jmp     run_ret

# ---------------------------------------------------------------------------
# str_eq: rdi, rsi -> eax = 1 if equal NUL-terminated strings, else 0.
# ---------------------------------------------------------------------------
str_eq:
        xor     eax, eax
str_eq_loop:
        mov     cl, [rdi]
        mov     dl, [rsi]
        cmp     cl, dl
        jne     str_eq_out
        test    cl, cl
        jz      str_eq_yes
        inc     rdi
        inc     rsi
        jmp     str_eq_loop
str_eq_yes:
        mov     eax, 1
str_eq_out:
        ret

shell_return:
        add     rsp, FRAME
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbp
        pop     rbx
        xor     eax, eax
        ret

# ---------------------------------------------------------------------------
# Data (kept in .text so it is part of the flat blob).
# ---------------------------------------------------------------------------
path_dirs:
        .asciz  "/usr/local/bin"
        .asciz  "/usr/bin"
        .asciz  "/bin"
        .asciz  "/usr/sbin"
        .asciz  "/sbin"
        .byte   0

str_exit:
        .asciz  "exit"
str_cd:
        .asciz  "cd"
str_slash:
        .asciz  "/"

msg_not_found:
        .ascii  "\n"
