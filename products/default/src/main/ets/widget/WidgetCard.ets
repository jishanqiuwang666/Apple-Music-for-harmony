/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

let storage = new LocalStorage();

/**
 * 2×2 音乐桌面服务卡片。布局参照用户截图并已按真机反馈迭代：
 * 左上 68×68 圆角封面，下方 15fp 白色加粗曲名 + 12fp 暖灰艺人名，
 * 底部为 30vp 上一首/下一首 Symbol 与 34vp 最中间暂停键（去圆形底，只留图标）。
 * 三键使用 postCardAction('call') 后台控制播放；
 * 点击封面/曲名/艺人使用 postCardAction('router') 打开应用。
 */
@Entry(storage)
@Component
struct WidgetCard {
  @LocalStorageProp('title') title: string = '暂无播放';
  @LocalStorageProp('artist') artist: string = '';
  @LocalStorageProp('isPlaying') isPlaying: boolean = false;
  @LocalStorageProp('imgName') imgName: string = '';

  private sendCall(method: string): void {
    postCardAction(this, {
      action: 'call',
      abilityName: 'MusichomeAbility',
      params: {
        method: method
      }
    });
  }

  private openApp(): void {
    postCardAction(this, {
      action: 'router',
      abilityName: 'MusichomeAbility'
    });
  }

  build() {
    Column() {
      // 顶部：左上角 68×68 圆角专辑封面。
      Row() {
        Stack() {
          if (this.imgName !== '') {
            Image('memory://' + this.imgName)
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Cover)
              .borderRadius(6)
          } else {
            Column() {
              SymbolGlyph($r('sys.symbol.music_note_list'))
                .fontSize(26)
                .fontColor(['#88FFFFFF'])
            }
            .width('100%')
            .height('100%')
            .borderRadius(6)
            .backgroundColor('#33FFFFFF')
            .justifyContent(FlexAlign.Center)
          }
        }
        .width(68)
        .height(68)
        .borderRadius(6)
        .clip(true)
        .onClick(() => {
          this.openApp();
        })
      }
      .width('100%')
      .padding({ left: 4 })
      .alignItems(VerticalAlign.Top)

      // 曲名 / 艺人：真机反馈后放大加粗（15fp Bold + 12fp Medium）。
      Column({ space: 2 }) {
        Text(this.title)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .lineHeight(15)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.artist)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor('#B9B5B1')
          .lineHeight(12)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .width('100%')
      .padding({ left: 4 })
      .alignItems(HorizontalAlign.Start)
      .margin({ top: 5 })
      .onClick(() => {
        this.openApp();
      })

      // 弹性占位，把三键控制行固定到卡片底部。
      Blank()
        .layoutWeight(1)

      // 底部三键：30vp 上一首/下一首 + 34vp 最中间暂停键（去圆形底，只留图标）。
      Row() {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.backward_end_fill'))
            .fontSize(28)
            .fontColor(['#E3E2E1'])
        }
        .width(30)
        .height(30)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.sendCall('prev');
        })

        Button({ type: ButtonType.Circle }) {
          SymbolGlyph(this.isPlaying
            ? $r('sys.symbol.pause_round_triangle_fill')
            : $r('sys.symbol.play_round_triangle_fill'))
            .fontSize(32)
            .fontColor(['#E3E2E1'])
        }
        .width(34)
        .height(34)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.sendCall('playPause');
        })

        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.forward_end_fill'))
            .fontSize(28)
            .fontColor(['#E3E2E1'])
        }
        .width(30)
        .height(30)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.sendCall('next');
        })
      }
      .width('100%')
      .height(34)
      .justifyContent(FlexAlign.SpaceBetween)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 9 })
    .linearGradient({
      angle: 180,
      colors: [['#3A2D24', 0.0], ['#241A14', 1.0]]
    })
    .borderRadius(8)
    .clip(true)
  }
}
