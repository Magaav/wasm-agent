-- A module the measured fixture loads through EMBEDDED (docs/KERNEL.md, "A2.3"). Its size is
-- the point: parsing it is work a pooled instance should do once, not once per run, and the
-- source is fetched from the kernel once per instance because the guest snapshots it.
local M = {}

function M.f1(x) return x + 1 end
function M.f2(x) return x + 2 end
function M.f3(x) return x + 3 end
function M.f4(x) return x + 4 end
function M.f5(x) return x + 5 end
function M.f6(x) return x + 6 end
function M.f7(x) return x + 7 end
function M.f8(x) return x + 8 end
function M.f9(x) return x + 9 end
function M.f10(x) return x + 10 end
function M.f11(x) return x + 11 end
function M.f12(x) return x + 12 end
function M.f13(x) return x + 13 end
function M.f14(x) return x + 14 end
function M.f15(x) return x + 15 end
function M.f16(x) return x + 16 end
function M.f17(x) return x + 17 end
function M.f18(x) return x + 18 end
function M.f19(x) return x + 19 end
function M.f20(x) return x + 20 end
function M.f21(x) return x + 21 end
function M.f22(x) return x + 22 end
function M.f23(x) return x + 23 end
function M.f24(x) return x + 24 end
function M.f25(x) return x + 25 end
function M.f26(x) return x + 26 end
function M.f27(x) return x + 27 end
function M.f28(x) return x + 28 end
function M.f29(x) return x + 29 end
function M.f30(x) return x + 30 end
function M.f31(x) return x + 31 end
function M.f32(x) return x + 32 end
function M.f33(x) return x + 33 end
function M.f34(x) return x + 34 end
function M.f35(x) return x + 35 end
function M.f36(x) return x + 36 end
function M.f37(x) return x + 37 end
function M.f38(x) return x + 38 end
function M.f39(x) return x + 39 end
function M.f40(x) return x + 40 end
function M.f41(x) return x + 41 end
function M.f42(x) return x + 42 end
function M.f43(x) return x + 43 end
function M.f44(x) return x + 44 end
function M.f45(x) return x + 45 end
function M.f46(x) return x + 46 end
function M.f47(x) return x + 47 end
function M.f48(x) return x + 48 end
function M.f49(x) return x + 49 end
function M.f50(x) return x + 50 end
function M.f51(x) return x + 51 end
function M.f52(x) return x + 52 end
function M.f53(x) return x + 53 end
function M.f54(x) return x + 54 end
function M.f55(x) return x + 55 end
function M.f56(x) return x + 56 end
function M.f57(x) return x + 57 end
function M.f58(x) return x + 58 end
function M.f59(x) return x + 59 end
function M.f60(x) return x + 60 end
function M.f61(x) return x + 61 end
function M.f62(x) return x + 62 end
function M.f63(x) return x + 63 end
function M.f64(x) return x + 64 end
function M.f65(x) return x + 65 end
function M.f66(x) return x + 66 end
function M.f67(x) return x + 67 end
function M.f68(x) return x + 68 end
function M.f69(x) return x + 69 end
function M.f70(x) return x + 70 end
function M.f71(x) return x + 71 end
function M.f72(x) return x + 72 end
function M.f73(x) return x + 73 end
function M.f74(x) return x + 74 end
function M.f75(x) return x + 75 end
function M.f76(x) return x + 76 end
function M.f77(x) return x + 77 end
function M.f78(x) return x + 78 end
function M.f79(x) return x + 79 end
function M.f80(x) return x + 80 end
function M.f81(x) return x + 81 end
function M.f82(x) return x + 82 end
function M.f83(x) return x + 83 end
function M.f84(x) return x + 84 end
function M.f85(x) return x + 85 end
function M.f86(x) return x + 86 end
function M.f87(x) return x + 87 end
function M.f88(x) return x + 88 end
function M.f89(x) return x + 89 end
function M.f90(x) return x + 90 end
function M.f91(x) return x + 91 end
function M.f92(x) return x + 92 end
function M.f93(x) return x + 93 end
function M.f94(x) return x + 94 end
function M.f95(x) return x + 95 end
function M.f96(x) return x + 96 end
function M.f97(x) return x + 97 end
function M.f98(x) return x + 98 end
function M.f99(x) return x + 99 end
function M.f100(x) return x + 100 end
function M.f101(x) return x + 101 end
function M.f102(x) return x + 102 end
function M.f103(x) return x + 103 end
function M.f104(x) return x + 104 end
function M.f105(x) return x + 105 end
function M.f106(x) return x + 106 end
function M.f107(x) return x + 107 end
function M.f108(x) return x + 108 end
function M.f109(x) return x + 109 end
function M.f110(x) return x + 110 end
function M.f111(x) return x + 111 end
function M.f112(x) return x + 112 end
function M.f113(x) return x + 113 end
function M.f114(x) return x + 114 end
function M.f115(x) return x + 115 end
function M.f116(x) return x + 116 end
function M.f117(x) return x + 117 end
function M.f118(x) return x + 118 end
function M.f119(x) return x + 119 end
function M.f120(x) return x + 120 end

function M.total(n)
  local sum = 0
  for i = 1, n do sum = sum + i end
  return sum
end

return M
