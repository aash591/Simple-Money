/// The app's chart kit. Screens import this one file, hand a chart data in
/// the shared shapes ([ChartSeries] for anything plotted over slots,
/// [ChartEntry] for a labelled value) and get back a widget that already
/// matches every other chart in the app.
///
/// Nothing here knows about money, months or categories — that keeps a chart
/// reusable on any screen. Formatting is the caller's job, passed in as a
/// `formatValue` callback.
///
/// | Question the screen is asking | Widget |
/// |---|---|
/// | How does this compare across months/days? | [BarChart] |
/// | What is this made of, in order? | [RankedBarChart] |
/// | How did it move over time? | [LineChart] |
/// | What share is each part of the whole? | [PieChart] |
/// | ...and should it label itself, with no legend? | [CalloutDonutChart] |
/// | Is this rising or falling? (in a row or tile) | [Sparkline] |
library;

export 'bar_chart.dart';
export 'callout_donut_chart.dart';
export 'chart_data.dart';
export 'chart_frame.dart';
export 'chart_legend.dart';
export 'chart_palette.dart';
export 'line_chart.dart';
export 'pie_chart.dart';
export 'ranked_bar_chart.dart';
export 'sparkline.dart';
