/// 主面板（MainPage 的 NaviPane）标签页下标。
///
/// 搜索页等入口需要「跳到发现/分类页」，但 features 层不能反向依赖 app_shell，
/// 下标就放在 foundation 里定义一份；MainPage 里 _pages 的顺序必须与这里一致。
abstract final class HomeTabs {
  static const home = 0;
  static const favorites = 1;
  static const explore = 2;
  static const categories = 3;
}
