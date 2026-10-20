# Generate many distinct, reconvergent slices of a common chain. Membership
# work must exhaust the bounded analysis before any IR emission.
print('define i32 @budget(ptr %a, i64 %n) {\nentry:\n  br label %loop\nloop:')
print('  %i = phi i64 [0, %entry], [%next, %loop]')
print('  %s = phi i32 [7, %entry], [%u63, %loop]')
print('  %x = load i32, ptr %a')
previous = '%x'
for i in range(40):
    print(f'  %c{i} = mul i32 {previous}, 13')
    previous = f'%c{i}'
for i in range(64):
    print(f'  %r{i} = xor i32 {previous}, {i + 1}')
previous = '%s'
for i in range(64):
    print(f'  %u{i} = add i32 {previous}, %r{i}')
    previous = f'%u{i}'
print('''  %next = add i64 %i, 1
  %more = icmp ne i64 %next, %n
  br i1 %more, label %loop, label %exit
exit:
  %result = phi i32 [%u63, %loop]
  ret i32 %result
}''')
