import 'package:flutter/material.dart';
import 'package:venera_unified/components/effects.dart';
import 'package:venera_unified/foundation/context.dart';
import 'package:venera_unified/foundation/widget_utils.dart';

/// 阅读器顶栏内容的最大宽度。
///
/// 超过这个宽度时内容居中而不是铺满，和底部控制岛保持同一视觉宽度；
/// 手机竖屏本来就窄于这个值，行为不变。
const double readerTopBarMaxWidth = 540;

class ReaderTopBar extends StatelessWidget {
  const ReaderTopBar({
    super.key,
    required this.title,
    this.chapterTitle,
    required this.actions,
    required this.onBack,
  });
  final String title;
  final String? chapterTitle;
  final List<Widget> actions;
  final VoidCallback onBack;
  @override
  Widget build(BuildContext context) {
    return BlurEffect(
      child: Container(
        padding: EdgeInsets.only(top: context.padding.top),
        decoration: BoxDecoration(
          color: context.colorScheme.surface.toOpacity(0.92),
          border: Border(
            bottom: BorderSide(color: Colors.grey.toOpacity(0.5), width: 0.5),
          ),
        ),
        child: Padding(
          padding: EdgeInsets.only(
            left: context.padding.left,
            right: context.padding.right,
          ),
          child: Align(
            alignment: Alignment.center,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: readerTopBarMaxWidth),
              child: Row(
                children: [
                  const SizedBox(width: 8),
                  BackButton(onPressed: onBack),
                  const SizedBox(width: 8),
                  Expanded(
                    child: chapterTitle == null
                        ? Text(
                            title,
                            style: ts.s18,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                title,
                                style: ts.s16,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                chapterTitle!,
                                style: ts.s12,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                  ),
                  const SizedBox(width: 8),
                  ...actions,
                  const SizedBox(width: 8),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
