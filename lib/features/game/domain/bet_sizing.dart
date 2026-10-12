import 'preflop_ranges.dart';

/// 翻前加注尺度的总表：开池、3bet、4bet / 挤压的倍数都集中在这里。
///
/// 之前这些数字散在三个地方：位置系数埋在 `PreflopRanges.openSizeFactor`、
/// 3bet/4bet 的倍数写死在 AiPlayer 的 `_threeBetSize` / `_fourBetSize` 里、
/// 轻 3bet 还另抄了一个 `* 3`。想调「AI 加注凶不凶」得翻三个文件，而且很容易
/// 改漏一处（两处尺寸互相打架）。集中到这一张表之后，调参只改这里。
///
/// 表里所有的「×」都是相对**当前最高注**的倍数——加注一路以上一次加注为基准
/// （3bet 对着开池算、4bet 对着 3bet 算），不是固定总额。跟引擎里
/// `minRaiseTo = 当前最高注 + 上一次加注幅度` 是同一条口径。
///
/// 风格之间还有三个乘数（开池基准 bb、4bet 倾向、3bet 范围宽窄），在
/// `ai_player.dart` 里每种风格各自一张表——这里管的是**全桌共用**的尺度。
class PreflopSizing {
  const PreflopSizing({
    this.openLimpAddBb = 1.0,
    this.threeBetIp = 3.0,
    this.threeBetOop = 4.0,
    this.threeBetMin = 3.0,
    this.threeBetPerLimperBb = 1.0,
    this.fourBetIp = 2.2,
    this.fourBetOop = 2.6,
    this.fourBetJamStackFrac = 0.4,
    this.fourBetCallRatio = 2.2,
    this.fiveBetRatio = 2.5,
    this.fiveBetJamStackFrac = 0.35,
  });

  /// 全桌默认尺度。想整体调凶/调紧，从这份拷贝改起。
  static const standard = PreflopSizing();

  /// 开池：每个已经溜入的人多收多少 bb（隔离他们，也把底池做大）。
  final double openLimpAddBb;

  /// 3bet：有位置 / 无位置时相对当前注的倍数。
  ///
  /// 无位置要加得更多——不然对手用跟注的赔率就能看翻牌，我们拿好牌反而
  /// 只赢一个小底池。
  final double threeBetIp;
  final double threeBetOop;

  /// 3bet 的下限倍数：位置系数再小也不能低于这条线。
  /// 轻 3bet（A5s 那类）也按这个尺寸打——诈唬和价值用同一个尺寸才读不出来。
  final double threeBetMin;

  /// 3bet / 挤压：每个已经进池的人再加多少 bb（不能让跟注者用便宜价格进来）。
  final double threeBetPerLimperBb;

  /// 4bet：有位置 / 无位置时相对当前注的倍数。
  final double fourBetIp;
  final double fourBetOop;

  /// 4bet 的额度一旦压进自己筹码的这个比例，就别再留后手了——4bet 完还想
  /// 弃牌是最亏的打法，直接推到全下。
  final double fourBetJamStackFrac;

  /// 5bet：相对当前注（也就是对方 4bet 的额度）的倍数。
  ///
  /// 翻前的加注战到 5bet 就结束了：再往上没有 6bet 的余地，所以这一注打的
  /// 不是「再加点价」，而是把整条筹码线一次送出去。倍数按深筹码的常规
  /// 2.5 倍定（100bb 那种深度会直接走 [fiveBetJamStackFrac] 那条线推光，
  /// 只有 200bb 往上才用得到这个数）。
  final double fiveBetRatio;

  /// 5bet 出去之后还剩不到自己筹码的这个比例，就别留后手了，直接推全下。
  ///
  /// 100bb 上下：4bet 到 18bb、我们再 5bet 到 45bb，手上只剩五十五个 bb，
  /// 后面每条街都是「推或被推」——那笔后手其实没有打的价值，不如现在就
  /// 把弃牌率也一起买了。200bb 往上这个数不会被触发，5bet 留一个真后手
  /// 反而更值钱（AA 在深筹码里想打到全下，靠的是翻后的三条街）。
  final double fiveBetJamStackFrac;

  /// 「这次的 4bet 到底算不算大」的分界线：4bet 额度 / 上一次 3bet 额度
  /// 超过这个倍数，就跟被推全下没两样，QQ/JJ 这类牌不该再想着跟注。
  ///
  /// 标准 4bet 是 3bet 的 2.2~2.8 倍（没位置更大）。这不是一个「越大越
  /// 该弃」的连续量，而是要不要留跟注范围的分水岭：2 倍出头还是「加个价」，
  /// 我们跟进去翻后还有位置、还有后手可以打；超过这条线对手基本是把自己
  /// 套牢了，他跟注范围里已经没有我们能压住的东西，跟进去就是纯送。
  final double fourBetCallRatio;

  /// 开池的位置系数：前位开得大一点（要保护、要隔离），后位偷盲可以小一点
  /// （同样能拿下盲注，还省筹码）。小盲没位置，照前位开。
  double openFactor(Seat seat) => switch (seat) {
        Seat.ep => 1.0,
        Seat.mp => 0.95,
        Seat.co => 0.88,
        Seat.btn => 0.82,
        Seat.sb => 1.0,
        Seat.bb => 1.0,
      };
}
