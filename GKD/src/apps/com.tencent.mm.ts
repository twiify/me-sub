import { defineGkdApp } from '@gkd-kit/define';

export default defineGkdApp({
  id: 'com.tencent.mm',
  name: '微信',
  groups: [
    {
      key: 1,
      name: '其他广告-订阅号消息列表广告',
      desc: '自动点击 [X]',
      enable: false,
      activityIds: [
        'com.tencent.mm.plugin.brandservice.ui.flutter.BizFlutterTLFlutterViewActivity',
      ],
      rules: [
        {
          key: 1,
          name: '点击 [X]',
          matches: [
            'View[childCount>=2] >n View[desc$="推​荐​"][childCount>=2] > ImageView[clickable=true][visibleToUser=true]',
          ],
        },
        {
          key: 2,
          name: '点击 [不喜欢此类视频]',
          preKeys: 1,
          matches: ['[desc="不喜欢此类视频"][clickable=true]'],
        },
        {
          key: 3,
          name: '点击 [确定]',
          preKeys: 2,
          matches: '[desc="确定"][clickable=true]',
        },
      ],
    },
    {
      key: 2,
      name: '其他广告-订阅号文章广告',
      desc: '自动点击关闭广告',
      enable: false,
      activityIds: [
        'com.tencent.mm.plugin.brandservice.ui.timeline.preload.ui.TmplWebView',
        'com.tencent.mm.plugin.brandservice.ui.timeline.preload.ui.TmplWebViewMMUI',
        'com.tencent.mm.plugin.brandservice.ui.timeline.preload.ui.TmplWebViewTooLMpUI',
        'com.tencent.mm.plugin.webview.ui.tools.fts.MMSosWebViewUI',
      ],
      rules: [
        {
          key: 1,
          name: '点击 [广告] 按钮',
          matches: [
            '[name$=".View"||name$=".TextView"][text^="广告"][visibleToUser=true] <n @View < View[childCount=1] <<3 View[childCount=1] <<2 View[childCount=1]',
          ],
        },
        {
          key: 2,
          name: '点击 [不感兴趣] 或 [关闭此广告]',
          preKeys: [1],
          matches: [
            '[text*="广告"&&text.length<5] <n View < View >n [text="不感兴趣"||text="关闭此广告"][visibleToUser=true]',
          ],
        },
        {
          key: 3,
          name: '点击 [与我无关]',
          preKeys: [1, 2],
          matches: [
            '[text*="广告"&&text.length<5] <n View < View >n [text="与我无关"][visibleToUser=true]',
          ],
        },
      ],
    },
    {
      key: 3,
      name: '功能优化-自动选中发送原图',
      desc: '发送图片和视频时自动选中底部的发送原图',
      enable: false,
      quickFind: true,
      activityIds: [
        'com.tencent.mm.plugin.gallery.ui.AlbumPreviewUI',
        'com.tencent.mm.plugin.gallery.ui.ImagePreviewUI',
      ],
      rules: '@[desc="未选中,原图,复选框"] + [text="原图"]',
    },
    {
      key: 4,
      name: '功能优化-自动领取微信红包',
      desc: '自动领取私聊、群聊红包',
      enable: false,
      activityIds: [
        'com.tencent.mm.plugin.luckymoney.ui.LuckyMoneyBeforeDetailUI',
        'com.tencent.mm.plugin.luckymoney.ui.LuckyMoneyNotHookReceiveUI',
        'com.tencent.mm.ui.LauncherUI',
      ],
      rules: [
        {
          key: 1,
          name: '点击红包 [开]',
          // Button[desc="开"] 会在出现金币动画时会消失
          matches: ['ImageButton[desc="开"] + Button[desc="开"]'],
        },
        {
          key: 2,
          name: '点击别人发的红包',
          // 第一个 LinearLayout[childCount=1] 区分是自己发的红包还是别人发的
          // 第二个 LinearLayout[childCount=1] 区分这个红包是否被领取过
          matches: [
            'LinearLayout[childCount=1] >5 LinearLayout[childCount=1] - ImageView < LinearLayout + View + RelativeLayout > TextView[text="微信红包"][id!=null]',
          ],
        },
        {
          name: '从红包结算界面返回',
          preKeys: [1, 2],
          matches: 'ImageView[desc="返回"]',
        },
      ],
    },
  ],
});
