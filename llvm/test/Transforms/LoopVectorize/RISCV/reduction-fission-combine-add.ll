; RUN: opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v,+m -force-vector-interleave=1 -enable-vplan-reduction-fission -tail-folding-policy=dont-fold-tail -S %s -o %t
; RUN: FileCheck %s < %t
; RUN: llc -mtriple=riscv64 -mattr=+v,+m -verify-machineinstrs %t -o /dev/null
; RUN: opt -passes=loop-vectorize -mtriple=riscv64 -mattr=+v,+m -force-vector-interleave=1 -enable-vplan-reduction-fission -vplan-reduction-fission-combine-add-contributions=false -S %s | FileCheck %s --check-prefix=OLD
; RUN: sed 's/, 1024$/, 257/' %s | opt -passes='loop-vectorize,verify<domtree>,verify<loops>,verify<scalar-evolution>' -verify-each -mtriple=riscv64 -mattr=+v,+m -force-vector-interleave=1 -enable-vplan-reduction-fission -S -o %t.tail
; RUN: FileCheck %s --check-prefix=TAIL < %t.tail
; RUN: llc -mtriple=riscv64 -mattr=+v,+m -verify-machineinstrs %t.tail -o /dev/null
;
; Two unshared integer contributions per filter reduction should be combined
; in a NEW fission candidate, not stored in four full-length arrays. Short
; sum/square reductions stay in the accumulator stage.
; CHECK-LABEL: define {{.*}}@aom_blockiness_horizontal(
; CHECK-COUNT-2: alloca [1024 x i32]
; CHECK-NOT: alloca [1024 x i32]
; CHECK: vector.fission.producer.body:
; CHECK-COUNT-2: store <vscale x {{[0-9]+}} x i32>
; CHECK-NOT: store <vscale x
; CHECK: vector.fission.producer.body.middle:
; CHECK: vector.fission.accumulator.body:
; CHECK-COUNT-2: load <vscale x {{[0-9]+}} x i32>
; CHECK-NOT: load <vscale x {{[0-9]+}} x i32>
; CHECK: vector.fission.accumulator.body.middle:
;
; OLD-COUNT-4: alloca [1024 x i32]
; OLD-NOT: alloca [1024 x i32]
; OLD: vector.fission.producer.body:
; TAIL-COUNT-2: alloca [257 x i32]
; TAIL-NOT: alloca [257 x i32]
; TAIL: scalar.fission.producer.body:
; TAIL-COUNT-2: store i32
; TAIL-NOT: store i32
; TAIL: scalar.fission.producer.body.middle:
; TAIL: scalar.fission.accumulator.body:
; TAIL-COUNT-2: load i32
; TAIL-NOT: load i32
; TAIL: scalar.fission.accumulator.body.middle:
source_filename = "reduction-fission-combine-add.c"
target datalayout = "e-m:e-p:64:64-i64:64-i128:128-n32:64-S128"
target triple = "riscv64-unknown-unknown-elf"

; Function Attrs: nofree noinline norecurse nosync nounwind memory(argmem: read) vscale_range(2,1024)
define dso_local signext i32 @aom_blockiness_horizontal(ptr noalias noundef readonly captures(none) %0, i32 noundef signext %1, ptr noalias noundef readonly captures(none) %2, i32 noundef signext %3, i32 noundef signext %4, ptr noalias noundef readnone captures(none) %5, ptr noalias noundef readnone captures(none) %6) local_unnamed_addr #0 {
  %8 = sext i32 %1 to i64
  %9 = mul i32 %1, -2
  %10 = sext i32 %9 to i64
  %11 = sub i32 0, %1
  %12 = sext i32 %11 to i64
  %13 = sext i32 %3 to i64
  %14 = mul i32 %3, -2
  %15 = sext i32 %14 to i64
  %16 = sub i32 0, %3
  %17 = sext i32 %16 to i64
  br label %22

18:                                               ; preds = %22
  %19 = tail call noundef range(i32 0, -2147483647) i32 @llvm.abs.i32(i32 %65, i1 false)
  %20 = tail call noundef range(i32 0, -2147483647) i32 @llvm.abs.i32(i32 %48, i1 false)
  %21 = icmp sgt i32 %19, %20
  br i1 %21, label %76, label %89

22:                                               ; preds = %7, %22
  %23 = phi ptr [ %0, %7 ], [ %73, %22 ]
  %24 = phi ptr [ %2, %7 ], [ %74, %22 ]
  %25 = phi i32 [ 0, %7 ], [ %72, %22 ]
  %26 = phi i32 [ 0, %7 ], [ %71, %22 ]
  %27 = phi i32 [ 0, %7 ], [ %69, %22 ]
  %28 = phi i32 [ 0, %7 ], [ %68, %22 ]
  %29 = phi i32 [ 0, %7 ], [ %66, %22 ]
  %30 = phi i32 [ 0, %7 ], [ %65, %22 ]
  %31 = phi i32 [ 0, %7 ], [ %48, %22 ]
  %32 = getelementptr inbounds i8, ptr %23, i64 %8
  %33 = load i8, ptr %32, align 1, !tbaa !7
  %34 = zext i8 %33 to i32
  %35 = getelementptr inbounds i8, ptr %23, i64 %10
  %36 = load i8, ptr %35, align 1, !tbaa !7
  %37 = zext i8 %36 to i32
  %38 = sub nsw i32 %34, %37
  %39 = shl nsw i32 %38, 1
  %40 = getelementptr inbounds i8, ptr %23, i64 %12
  %41 = load i8, ptr %40, align 1, !tbaa !7
  %42 = zext i8 %41 to i32
  %43 = load i8, ptr %23, align 1, !tbaa !7
  %44 = zext i8 %43 to i32
  %45 = sub nsw i32 %42, %44
  %46 = mul nsw i32 %45, 6
  %47 = add i32 %39, %31
  %48 = add i32 %47, %46
  %49 = getelementptr inbounds i8, ptr %24, i64 %13
  %50 = load i8, ptr %49, align 1, !tbaa !7
  %51 = zext i8 %50 to i32
  %52 = getelementptr inbounds i8, ptr %24, i64 %15
  %53 = load i8, ptr %52, align 1, !tbaa !7
  %54 = zext i8 %53 to i32
  %55 = sub nsw i32 %51, %54
  %56 = shl nsw i32 %55, 1
  %57 = getelementptr inbounds i8, ptr %24, i64 %17
  %58 = load i8, ptr %57, align 1, !tbaa !7
  %59 = zext i8 %58 to i32
  %60 = load i8, ptr %24, align 1, !tbaa !7
  %61 = zext i8 %60 to i32
  %62 = sub nsw i32 %59, %61
  %63 = mul nsw i32 %62, 6
  %64 = add i32 %56, %30
  %65 = add i32 %64, %63
  %66 = add i32 %29, %44
  %67 = mul nuw nsw i32 %44, %44
  %68 = add i32 %67, %28
  %69 = add i32 %27, %42
  %70 = mul nuw nsw i32 %42, %42
  %71 = add i32 %70, %26
  %72 = add nuw nsw i32 %25, 1
  %73 = getelementptr inbounds nuw i8, ptr %23, i64 1
  %74 = getelementptr inbounds nuw i8, ptr %24, i64 1
  %75 = icmp eq i32 %72, 1024
  br i1 %75, label %18, label %22, !llvm.loop !10

76:                                               ; preds = %18
  %77 = sdiv i32 %71, 1024
  %78 = sdiv i32 %69, 1024
  %79 = mul i32 %78, %78
  %80 = sdiv i32 %68, 1024
  %81 = sdiv i32 %66, 1024
  %82 = mul i32 %81, %81
  %83 = sub i32 %19, %20
  %84 = add i32 %79, %82
  %85 = add nsw i32 %80, 1
  %86 = add nsw i32 %85, %77
  %87 = sub i32 %86, %84
  %88 = sdiv i32 %83, %87
  br label %89

89:                                               ; preds = %18, %76
  %90 = phi i32 [ %88, %76 ], [ 0, %18 ]
  ret i32 %90
}

; Function Attrs: nocallback nofree nosync nounwind speculatable willreturn memory(none)
declare i32 @llvm.abs.i32(i32, i1 immarg) #1

attributes #0 = { nofree noinline norecurse nosync nounwind memory(argmem: read) vscale_range(2,1024) "no-builtins" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="generic-rv64" "target-features"="+64bit,+a,+c,+d,+f,+m,+v,+zaamo,+zalrsc,+zca,+zcd,+zicsr,+zifencei,+zmmul,+zve32f,+zve32x,+zve64d,+zve64f,+zve64x,+zvl128b,+zvl32b,+zvl64b,-b,-e,-experimental-p,-experimental-smctr,-experimental-ssctr,-experimental-svukte,-experimental-xqccmp,-experimental-xqcia,-experimental-xqciac,-experimental-xqcibi,-experimental-xqcibm,-experimental-xqcicli,-experimental-xqcicm,-experimental-xqcics,-experimental-xqcicsr,-experimental-xqciint,-experimental-xqciio,-experimental-xqcilb,-experimental-xqcili,-experimental-xqcilia,-experimental-xqcilo,-experimental-xqcilsm,-experimental-xqcisim,-experimental-xqcisls,-experimental-xqcisync,-experimental-xrivosvisni,-experimental-xrivosvizip,-experimental-xsfmclic,-experimental-xsfsclic,-experimental-zalasr,-experimental-zicfilp,-experimental-zicfiss,-experimental-zvbc32e,-experimental-zvkgs,-experimental-zvqdotq,-h,-q,-relax,-sdext,-sdtrig,-sha,-shcounterenw,-shgatpa,-shlcofideleg,-shtvala,-shvsatpa,-shvstvala,-shvstvecd,-smaia,-smcdeleg,-smcntrpmf,-smcsrind,-smdbltrp,-smepmp,-smmpm,-smnpm,-smrnmi,-smstateen,-ssaia,-ssccfg,-ssccptr,-sscofpmf,-sscounterenw,-sscsrind,-ssdbltrp,-ssnpm,-sspm,-ssqosid,-ssstateen,-ssstrict,-sstc,-sstvala,-sstvecd,-ssu64xl,-supm,-svade,-svadu,-svbare,-svinval,-svnapot,-svpbmt,-svvptc,-xandesbfhcvt,-xandesperf,-xandesvbfhcvt,-xandesvdot,-xandesvpackfph,-xandesvsintload,-xcvalu,-xcvbi,-xcvbitmanip,-xcvelw,-xcvmac,-xcvmem,-xcvsimd,-xmipscbop,-xmipscmov,-xmipslsp,-xsfcease,-xsfmm128t,-xsfmm16t,-xsfmm32a16f,-xsfmm32a32f,-xsfmm32a8f,-xsfmm32a8i,-xsfmm32t,-xsfmm64a64f,-xsfmm64t,-xsfmmbase,-xsfvcp,-xsfvfnrclipxfqf,-xsfvfwmaccqqq,-xsfvqmaccdod,-xsfvqmaccqoq,-xsifivecdiscarddlone,-xsifivecflushdlone,-xtheadba,-xtheadbb,-xtheadbs,-xtheadcmo,-xtheadcondmov,-xtheadfmemidx,-xtheadmac,-xtheadmemidx,-xtheadmempair,-xtheadsync,-xtheadvdot,-xventanacondops,-xwchc,-za128rs,-za64rs,-zabha,-zacas,-zama16b,-zawrs,-zba,-zbb,-zbc,-zbkb,-zbkc,-zbkx,-zbs,-zcb,-zce,-zcf,-zclsd,-zcmop,-zcmp,-zcmt,-zdinx,-zfa,-zfbfmin,-zfh,-zfhmin,-zfinx,-zhinx,-zhinxmin,-zic64b,-zicbom,-zicbop,-zicboz,-ziccamoa,-ziccamoc,-ziccif,-zicclsm,-ziccrse,-zicntr,-zicond,-zihintntl,-zihintpause,-zihpm,-zilsd,-zimop,-zk,-zkn,-zknd,-zkne,-zknh,-zkr,-zks,-zksed,-zksh,-zkt,-ztso,-zvbb,-zvbc,-zvfbfmin,-zvfbfwma,-zvfh,-zvfhmin,-zvkb,-zvkg,-zvkn,-zvknc,-zvkned,-zvkng,-zvknha,-zvknhb,-zvks,-zvksc,-zvksed,-zvksg,-zvksh,-zvkt,-zvl1024b,-zvl16384b,-zvl2048b,-zvl256b,-zvl32768b,-zvl4096b,-zvl512b,-zvl65536b,-zvl8192b" }
attributes #1 = { nocallback nofree nosync nounwind speculatable willreturn memory(none) }

!llvm.module.flags = !{!0, !1, !2, !4, !5}
!llvm.ident = !{!6}

!0 = !{i32 1, !"wchar_size", i32 4}
!1 = !{i32 1, !"target-abi", !"lp64d"}
!2 = !{i32 6, !"riscv-isa", !3}
!3 = !{!"rv64i2p1_m2p0_a2p1_f2p2_d2p2_c2p0_v1p0_zicsr2p0_zifencei2p0_zmmul1p0_zaamo1p0_zalrsc1p0_zca1p0_zcd1p0_zve32f1p0_zve32x1p0_zve64d1p0_zve64f1p0_zve64x1p0_zvl128b1p0_zvl32b1p0_zvl64b1p0"}
!4 = !{i32 1, !"Code Model", i32 3}
!5 = !{i32 8, !"SmallDataLimit", i32 0}
!6 = !{!"clang version 21.1.8 (https://github.com/llvm/llvm-project.git c11ba53844ae56ffdb97d9da61025e2b4508b86b)"}
!7 = !{!8, !8, i64 0}
!8 = !{!"omnipotent char", !9, i64 0}
!9 = !{!"Simple C/C++ TBAA"}
!10 = distinct !{!10, !11, !12}
!11 = !{!"llvm.loop.mustprogress"}
!12 = !{!"llvm.loop.unroll.disable"}
