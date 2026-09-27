/// 筹码数缩写：上万之后改写成「万」，免得一行里被长数字撑爆。
///
/// 放在单独一个文件里是因为对局页和总结页都要用：两边各自 import 一下就行，
/// 不用互相 import（那会绕成一个环）。
String compactChips(int v) {
  final n = v.abs();
  if (n < 10000) return '$v';
  return '${v < 0 ? '-' : ''}${(n / 10000).toStringAsFixed(1)}万';
}

/// 带正负号的筹码文案（`+1,200` / `-800`）——注意这里**不**缩写，
/// 给「单手最好/最差」这种需要看准数字的地方用。
String signedChips(int v) => '${v > 0 ? '+' : ''}$v';
