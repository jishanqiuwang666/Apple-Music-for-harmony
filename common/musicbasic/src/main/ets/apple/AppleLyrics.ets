/**
 * Apple Music 歌词（TTML）
 *
 * 数据来源实测结论（2026-10-03，用本项目登录态真机凭据验证）：
 *   - 逐词：`GET {AMP}/v1/catalog/{storefront}/songs/{id}/syllable-lyrics?l=xx`
 *           返回 `data[0].attributes.ttml`，`<tt itunes:timing="Word">`，每行 `<p>` 内含
 *           若干 `<span begin end>`（一两个字一个 span）。
 *   - 逐行：`.../lyrics`，`<tt itunes:timing="Line">`，`<p>` 内无 span。
 *   - **storefront 必须是账号所属区**（实测 cn 账号用 us/jp 请求一律 404
 *     `No related resources found for lyrics`），但曲目 id 可以用任意区的全球 id
 *     —— 也就是说资料库里那首美国歌，用 cn 区照样能取到歌词。
 *   - 中文歌常带 `<translation xml:lang="zh-Hans">` 翻译层；和声用
 *     `<span ttm:role="x-bg">` 包裹（内层 span 才带时间）。
 *   - 404 是正常的「这首歌没有歌词」，不是错误。
 *
 * 解析走轻量扫描而不是 XmlPullParser：TTML 由机器生成、结构固定，扫描器对
 * 命名空间/自闭合标签不敏感，也不会因为 Apple 哪天加个属性就解析失败。
 */
import { Logger } from '../util/Logger';
import { AppleApi } from './AppleApi';

const TAG: string = 'AppleLyrics';

/**
 * 歌词里可单独高亮的一小段（一个字 / 一个词 / 一个英文音节）。
 */
export class LyricWord {
  /** 显示文本（可能带前导/尾随空格）。 */
  public text: string = '';
  /** 相对整首歌的起始时间（毫秒）。 */
  public startMs: number = 0;
  /** 结束时间（毫秒）。 */
  public endMs: number = 0;
  /** true 表示和声（Apple 用 ttm:role="x-bg" 标记），渲染要弱化。 */
  public isBackground: boolean = false;
  /**
   * 本词在**整行文本里的起止下标**（左闭右开）。
   *
   * 有了它，就能在「繁体正文换成简体」时按位置把逐词时间平移过去 ——
   * 繁简绝大多数是 1:1 字符对应，直接把每个词的文本换成简体对应片段即可，
   * 逐字高亮因此不会丢。
   */
  public startIdx: number = 0;
  public endIdx: number = 0;
}

/**
 * 一行歌词。
 */
export class LyricLine {
  /** Apple 的行标识（`itunes:key`，形如 L1），用于对齐翻译层。 */
  public key: string = '';
  /** 段落类型（Verse / Chorus / Bridge / Intro / PreChorus ...）。 */
  public songPart: string = '';
  /** 行起始时间（毫秒）。 */
  public startMs: number = 0;
  /** 行结束时间（毫秒；无逐词时用它做整行高亮时长）。 */
  public endMs: number = 0;
  /** 纯文本（已剥掉标签、已反转义）。 */
  public text: string = '';
  /** 翻译层文本（没有则为空串）。 */
  public translation: string = '';
  /** 逐词片段；无逐词时间时为整行一个片段。 */
  public words: LyricWord[] = [];
  /** 本行是否真的有逐词时间。 */
  public hasWordTiming: boolean = false;

  /** 行时长（毫秒），至少 1ms 防除零。 */
  public durationMs(): number {
    const d: number = this.endMs - this.startMs;
    return d > 0 ? d : 1;
  }
}

/**
 * 一整首歌词。
 */
export class AppleLyric {
  /** Apple 曲目 id。 */
  public songId: string = '';
  /** 原文语言（`tt` 根节点的 xml:lang）。 */
  public language: string = '';
  /** 翻译层语言（空串表示没有翻译）。 */
  public translationLanguage: string = '';
  /** 整体是否有逐词时间。 */
  public hasWordTiming: boolean = false;
  /** 按时间升序的行。 */
  public lines: LyricLine[] = [];

  /** 没有任何可显示内容时为 true。 */
  public isEmpty(): boolean {
    return this.lines.length === 0;
  }
}

/** 一个 XML 元素的原始切分结果（属性串 +  innerXML）。 */
class XmlElement {
  /** 开始标签里的属性部分。 */
  public attrs: string = '';
  /** 标签包裹的内容（原始 XML）。 */
  public inner: string = '';
}

/** 解析 `<p>` 内层 span 时用的栈帧。 */
class SpanFrame {
  /** ttm:role（"x-bg" 表示和声）。 */
  public role: string = '';
  /** begin 属性原始值。 */
  public begin: string = '';
  /** end 属性原始值。 */
  public end: string = '';
}

/**
 * TTML 解析器：把 Apple 的歌词 XML 变成 {@link AppleLyric}。
 */
export class TtmlParser {
  /**
   * 解析 TTML 文本。
   *
   * @param ttml Apple 返回的 TTML 字符串。
   * @param songId 曲目 id（只用于回填到结果里）。
   * @returns 解析后的歌词；没有任何行时返回空 {@link AppleLyric}。
   */
  public static parse(ttml: string, songId: string): AppleLyric {
    const out: AppleLyric = new AppleLyric();
    out.songId = songId;
    if (ttml.length === 0) {
      return out;
    }
    out.language = TtmlParser.rootLang(ttml);
    const translations: Map<string, string> = TtmlParser.parseTranslations(ttml);

    const bodyStart: number = ttml.indexOf('<body');
    const body: string = bodyStart >= 0 ? ttml.substring(bodyStart) : ttml;
    const divs: XmlElement[] = TtmlParser.splitElements(body, 'div');
    // 有些曲目的 body 下直接是 <p>，没有 div 包一层
    const groups: XmlElement[] = divs.length > 0 ? divs : [TtmlParser.wrapWhole(body, 'div')];

    for (let g = 0; g < groups.length; g++) {
      const part: string = TtmlParser.attrOf(groups[g].attrs, 'itunes:songPart');
      const ps: XmlElement[] = TtmlParser.splitElements(groups[g].inner, 'p');
      for (let i = 0; i < ps.length; i++) {
        const line: LyricLine | undefined = TtmlParser.buildLine(ps[i], part, translations);
        if (line !== undefined) {
          out.lines.push(line);
        }
      }
    }

    out.lines.sort((a: LyricLine, b: LyricLine) => {
      return a.startMs - b.startMs;
    });
    // 行结束时间缺失时，用下一行的开始时间补（最后一行给 5s）
    for (let k = 0; k < out.lines.length; k++) {
      if (out.lines[k].endMs <= out.lines[k].startMs) {
        const nextStart: number = k + 1 < out.lines.length ? out.lines[k + 1].startMs : 0;
        out.lines[k].endMs = nextStart > out.lines[k].startMs ? nextStart : out.lines[k].startMs + 5000;
      }
    }
    out.hasWordTiming = out.lines.length > 0 && out.lines[0].hasWordTiming;
    if (translations.size > 0) {
      out.translationLanguage = TtmlParser.firstTranslationLang(ttml);
    }
    // ── 中文歌：只保留简体 ──
    //
    // 实测（周杰伦《晴天》，l=zh-Hans-CN）：Apple 返回的**主歌词本身是繁体**
    // （"故事的小黃花 / 從出生那年就飄著"），而 `<translation xml:lang="zh-Hans">`
    // 才是简体。于是歌词页上就成了「繁体正文 + 简体译文」两种并存
    // （用户反馈的正是这个）。
    //
    // 处理：如果正文看着是繁体、并且我们手里正好有 zh-Hans 这一层，
    // 就把简体层**当成正文**，并且**把逐词时间一起搬过去** ——
    // 繁简绝大多数是 1:1 字符对应（黃→黄、從→从…），照着每个词的字符区间
    // 把文本换成简体片段即可，逐字高亮完整保留（用户明确要求这一点）。
    // 少数长度不一致的行走「按比例映射区间」的近似路径，观感上仍是逐词。
    if (out.translationLanguage.indexOf('zh-Hans') === 0 && translations.size > 0) {
      let joined: string = '';
      for (let k = 0; k < out.lines.length; k++) {
        joined += out.lines[k].text;
      }
      if (TtmlParser.looksTraditional(joined)) {
        let replaced: number = 0;
        let keptTiming: number = 0;
        for (let k = 0; k < out.lines.length; k++) {
          const line: LyricLine = out.lines[k];
          const simplified: string | undefined = translations.get(line.key);
          if (simplified === undefined || simplified.length === 0) {
            continue;
          }
          if (line.words.length > 0 && simplified.length === line.text.length) {
            // 1:1 —— 逐词时间原样保留，只把文字换成简体
            for (let w = 0; w < line.words.length; w++) {
              const word: LyricWord = line.words[w];
              word.text = TtmlParser.substringSafe(simplified, word.startIdx, word.endIdx);
            }
            keptTiming++;
          } else if (line.words.length > 0) {
            // 字符数不同（少见）：按长度比例映射区间，仍然逐词
            const ratio: number = simplified.length / line.text.length;
            for (let w = 0; w < line.words.length; w++) {
              const word: LyricWord = line.words[w];
              const s: number = Math.min(simplified.length, Math.round(word.startIdx * ratio));
              const e: number = Math.min(simplified.length, Math.max(s, Math.round(word.endIdx * ratio)));
              word.startIdx = s;
              word.endIdx = e;
              word.text = TtmlParser.substringSafe(simplified, s, e);
            }
            keptTiming++;
          } else {
            line.hasWordTiming = false;
          }
          line.text = simplified;
          line.translation = '';
          replaced++;
        }
        if (replaced > 0) {
          out.translationLanguage = '';
          out.hasWordTiming = keptTiming > 0;
          Logger.info(TAG, `简体替换：${replaced}/${out.lines.length} 行，保留逐词 ${keptTiming} 行`);
        }
      }
    }
    // ── 译文与正文同语言：直接丢掉 ──
    //
    // 中文歌的 TTML 常常同时给「正文中文」和一层 `zh-Hans` 译文，而正文本来就
    // 是简体 —— 那层"译文"只是把同一句中文再说一遍。屏幕上就是「一句正文 +
    // 一行重复的中文」，还白占一行高度（这正是用户反馈的「中文歌句间空一大块」）。
    // 日文/韩文歌的中文译文是另一种语言，属于真译文，保留。
    // 注意顺序：必须在上面「繁体正文 → 用 zh-Hans 替换」之后判断，
    // 否则会把替换所需的简体层也一起丢掉（周杰伦那类歌会退回繁体）。
    // 注意：**不能只信 `<tt xml:lang>`** —— 实测 Apple 常把中文歌的根语言写成
    // `en`（`root=['en']` 而歌词是中文），那样 sameLanguage 永远不命中，
    // 中文歌就会一直显示一行重复的中文「译文」。所以这里补一条按正文
    // 实际字符的判断：正文全是汉字（没有假名/韩文）→ 它就是中文歌。
    let bodyText: string = '';
    for (let k = 0; k < out.lines.length; k++) {
      bodyText += out.lines[k].text;
    }
    const chineseBody: boolean = out.translationLanguage.indexOf('zh') === 0 &&
      TtmlParser.looksChinese(bodyText);
    if (out.translationLanguage.length > 0 && (chineseBody ||
      TtmlParser.sameLanguage(out.language, out.translationLanguage))) {
      for (let k = 0; k < out.lines.length; k++) {
        out.lines[k].translation = '';
      }
      Logger.info(TAG, `译文与正文同语言（${out.language}），已忽略`);
      out.translationLanguage = '';
    }
    Logger.info(TAG, `parse ${songId}: ${out.lines.length} 行, 逐词=${out.hasWordTiming}, 翻译=${out.translationLanguage}`);
    return out;
  }

  /**
   * 正文看起来是不是中文（汉字占比够高、且不含假名/韩文）。
   *
   * 用来兜底 Apple 把中文歌的 `<tt xml:lang>` 写成 `en` 的情况：
   * 那种时候只能看正文本身。日文歌含假名、韩文歌含谚文，都不会被误判成中文。
   */
  private static looksChinese(text: string): boolean {
    let han: number = 0;
    let kana: number = 0;
    let hangul: number = 0;
    let total: number = 0;
    for (let i = 0; i < text.length; i++) {
      const c: number = text.charCodeAt(i);
      if (c === 32 || c === 10 || c === 13 || c === 9) {
        continue;
      }
      total++;
      if (c >= 0x4E00 && c <= 0x9FFF) {
        han++;
      } else if (c >= 0x3040 && c <= 0x30FF) {
        kana++;
      } else if (c >= 0xAC00 && c <= 0xD7A3) {
        hangul++;
      }
    }
    if (total === 0 || kana > 0 || hangul > 0) {
      return false;
    }
    return han / total > 0.3;
  }

  /**
   * 两个语言标签是否属于同一种语言。
   *
   * 只比主语言前缀（`zh-Hans` 与 `zh-Hant` 都算 `zh`）：繁简属于同一种语言，
   * 不该被当成"真译文"展示。
   */
  private static sameLanguage(a: string, b: string): boolean {
    const x: string = a.length >= 2 ? a.substring(0, 2).toLowerCase() : '';
    const y: string = b.length >= 2 ? b.substring(0, 2).toLowerCase() : '';
    return x.length > 0 && x === y;
  }

  /** 取 `<tt>` 根节点的 xml:lang。 */
  private static rootLang(ttml: string): string {
    const tt: XmlElement[] = TtmlParser.splitElements(ttml, 'tt');
    if (tt.length === 0) {
      return '';
    }
    return TtmlParser.attrOf(tt[0].attrs, 'xml:lang');
  }

  /** 把整段当作一个元素（body 下没有 div 时的兜底）。 */
  private static wrapWhole(xml: string, tag: string): XmlElement {
    const el: XmlElement = new XmlElement();
    const gt: number = xml.indexOf('>', 0);
    el.inner = gt >= 0 ? xml.substring(gt + 1) : xml;
    return el;
  }

  /**
   * 解析 `<head><metadata><iTunesMetadata><translations>` 里的翻译/罗马音层。
   *
   * @returns 行标识（itunes:key）→ 翻译文本。
   */
  private static parseTranslations(ttml: string): Map<string, string> {
    const map: Map<string, string> = new Map<string, string>();
    // 只解析「挑中的那一个」翻译块 —— 不再把所有块都塞进同一个 map，
    // 否则简体会被繁体覆盖（或反之），屏幕上就成了繁简混杂。
    const block: XmlElement | undefined = TtmlParser.pickTranslationBlock(ttml);
    if (block === undefined) {
      return map;
    }
    const texts: XmlElement[] = TtmlParser.splitElements(block.inner, 'text');
    for (let k = 0; k < texts.length; k++) {
      const forKey: string = TtmlParser.attrOf(texts[k].attrs, 'for');
      if (forKey.length === 0) {
        continue;
      }
      const plain: string = TtmlParser.decode(TtmlParser.stripTags(texts[k].inner)).trim();
      if (plain.length > 0) {
        map.set(forKey, plain);
      }
    }
    return map;
  }

  /**
   * 从 `<head>` 里挑出**要用的那一个** `<translation>` 块。
   *
   * 中文歌的 TTML 常常同时带 `zh-Hans`（简体）和 `zh-Hant`（繁体）两个块。
   * 以前是「遍历全部、后面的覆盖前面的」，于是屏幕上会同时出现繁简两种
   * （用户反馈的问题）。现在只挑一个：
   * 简体最优 → 其他非中文语言（英译等）兜底 → **只有繁体时返回 undefined**
   * （主歌词本来就是中文，再来一层繁体就是繁简混杂）。
   */
  private static pickTranslationBlock(ttml: string): XmlElement | undefined {
    const headEnd: number = ttml.indexOf('</head>');
    const head: string = headEnd >= 0 ? ttml.substring(0, headEnd) : '';
    if (head.length === 0) {
      return undefined;
    }
    const blocks: XmlElement[] = TtmlParser.splitElements(head, 'translation');
    let fallback: XmlElement | undefined = undefined;
    for (let i = 0; i < blocks.length; i++) {
      const lang: string = TtmlParser.attrOf(blocks[i].attrs, 'xml:lang');
      if (lang.indexOf('zh-Hant') === 0) {
        continue;
      }
      if (lang.indexOf('zh-Hans') === 0) {
        return blocks[i];
      }
      if (fallback === undefined) {
        fallback = blocks[i];
      }
    }
    return fallback;
  }

  /**
   * 高频「繁简字形不同」的字，用来快速判断一段中文是不是繁体。
   *
   * 表里放的都是**繁体形**（"從""這""個"…），简体文本不会命中 ——
   * 不需要完整的繁简对照表，只要能判断「要不要拿简体层替换正文」就够了。
   */
  private static readonly TRAD_HINTS: string =
    '從這們個為說對時開關愛國學習車馬鳥魚體髮麵點後發現實東門問間麼著黃與來會沒還';

  /** 安全 substring：越界自动收敛，不会抛异常。 */
  private static substringSafe(text: string, from: number, to: number): string {
    const a: number = from < 0 ? 0 : (from > text.length ? text.length : from);
    const b: number = to < a ? a : (to > text.length ? text.length : to);
    return text.substring(a, b);
  }

  /**
   * 文本开头连续空白（空格/制表/换行）的个数。
   *
   * 不用 `trimStart()`：ArkTS 下拿不到就白搭，手写反而稳。
   */
  private static leadingSpaces(text: string): number {
    let i: number = 0;
    while (i < text.length) {
      const c: string = text.charAt(i);
      if (c !== ' ' && c !== '\t' && c !== '\n' && c !== '\r') {
        break;
      }
      i++;
    }
    return i;
  }

  /**
   * 判断文本看起来是不是繁体。
   *
   * @param text 拼接后的全部歌词正文。
   * @returns 命中 3 个以上繁体特征字即认为整篇是繁体。
   */
  public static looksTraditional(text: string): boolean {
    let hit: number = 0;
    for (let i = 0; i < text.length; i++) {
      if (TtmlParser.TRAD_HINTS.indexOf(text.charAt(i)) >= 0) {
        hit++;
        if (hit >= 3) {
          return true;
        }
      }
    }
    return false;
  }

  /** 翻译层的语言标签（与 {@link pickTranslationBlock} 挑的是同一个块）。 */
  private static firstTranslationLang(ttml: string): string {
    const block: XmlElement | undefined = TtmlParser.pickTranslationBlock(ttml);
    return block !== undefined ? TtmlParser.attrOf(block.attrs, 'xml:lang') : '';
  }

  /** 从一个 `<p>` 元素构造一行（解析失败返回 undefined）。 */
  private static buildLine(p: XmlElement, songPart: string, translations: Map<string, string>): LyricLine | undefined {
    const key: string = TtmlParser.attrOf(p.attrs, 'itunes:key');
    const startMs: number = TtmlParser.parseTime(TtmlParser.attrOf(p.attrs, 'begin'));
    const endMs: number = TtmlParser.parseTime(TtmlParser.attrOf(p.attrs, 'end'));
    const words: LyricWord[] = TtmlParser.parseWords(p.inner);
    let text: string = '';
    for (let i = 0; i < words.length; i++) {
      text += words[i].text;
    }
    if (text.trim().length === 0) {
      return undefined;
    }
    // 词的区间是相对「未裁剪的拼接串」记的，而 line.text 是裁剪后的 ——
    // 行首若有空白要把区间整体左移，否则逐词高亮会偏。
    const lead: number = TtmlParser.leadingSpaces(text);
    if (lead > 0) {
      for (let i = 0; i < words.length; i++) {
        words[i].startIdx -= lead;
        words[i].endIdx -= lead;
      }
    }
    const line: LyricLine = new LyricLine();
    line.key = key;
    line.songPart = songPart;
    line.startMs = startMs;
    line.endMs = endMs;
    line.text = text.trim();
    line.words = words;

    // 只有一个片段且没有真实逐词时间 → 整行高亮
    const timed: number = words.filter((w: LyricWord) => w.endMs > w.startMs).length;
    line.hasWordTiming = words.length > 1 && timed > 0;
    if (words.length === 1) {
      words[0].startMs = startMs;
      words[0].endMs = endMs > startMs ? endMs : startMs + 3000;
    }

    const tr: string | undefined = translations.get(key);
    line.translation = tr !== undefined ? tr : '';
    TtmlParser.fillGapTimes(line);
    return line;
  }

  /**
   * 给没有时间的片段（典型是 span 之间的空格）补时间，
   * 让高亮扫过去时是连续的，不会在空格处卡一下。
   */
  private static fillGapTimes(line: LyricLine): void {
    for (let i = 0; i < line.words.length; i++) {
      const w: LyricWord = line.words[i];
      if (w.endMs > w.startMs) {
        continue;
      }
      let prevEnd: number = line.startMs;
      for (let b = i - 1; b >= 0; b--) {
        if (line.words[b].endMs > 0) {
          prevEnd = line.words[b].endMs;
          break;
        }
      }
      let nextStart: number = line.endMs > line.startMs ? line.endMs : prevEnd + 1;
      for (let f = i + 1; f < line.words.length; f++) {
        if (line.words[f].endMs > line.words[f].startMs) {
          nextStart = line.words[f].startMs;
          break;
        }
      }
      w.startMs = prevEnd;
      w.endMs = nextStart > prevEnd ? nextStart : prevEnd + 1;
    }
  }

  /**
   * 扫一个 `<p>` 的内层，切出逐词片段（处理 `<span ttm:role="x-bg">` 嵌套）。
   *
   * @param inner `<p>` 的 innerXML。
   * @returns 顺序排列的片段（含无时间的间隔文本）。
   */
  public static parseWords(inner: string): LyricWord[] {
    const out: LyricWord[] = [];
    const stack: SpanFrame[] = [];
    let buf: string = '';
    let i: number = 0;
    const n: number = inner.length;
    /** 已产出的字符数（相对整行拼接串），用来给每个词记下区间。 */
    let acc: number = 0;

    const flush = (): void => {
      if (buf.length === 0) {
        return;
      }
      let begin: string = '';
      let end: string = '';
      let bg: boolean = false;
      for (let k = stack.length - 1; k >= 0; k--) {
        if (begin.length === 0 && stack[k].begin.length > 0) {
          begin = stack[k].begin;
          end = stack[k].end;
        }
        if (stack[k].role === 'x-bg') {
          bg = true;
        }
      }
      const w: LyricWord = new LyricWord();
      w.text = TtmlParser.decode(buf);
      w.startMs = TtmlParser.parseTime(begin);
      w.endMs = TtmlParser.parseTime(end);
      w.isBackground = bg;
      w.startIdx = acc;
      w.endIdx = acc + w.text.length;
      acc += w.text.length;
      out.push(w);
      buf = '';
    };

    while (i < n) {
      const lt: number = inner.indexOf('<', i);
      if (lt < 0) {
        buf += inner.substring(i);
        break;
      }
      buf += inner.substring(i, lt);
      if (inner.startsWith('</span', lt)) {
        flush();
        const gt: number = inner.indexOf('>', lt);
        if (gt < 0) {
          break;
        }
        stack.pop();
        i = gt + 1;
      } else if (inner.startsWith('<span', lt)) {
        const gt: number = inner.indexOf('>', lt);
        if (gt < 0) {
          break;
        }
        flush();
        const frame: SpanFrame = new SpanFrame();
        const attrs: string = inner.substring(lt + 5, gt);
        frame.role = TtmlParser.attrOf(attrs, 'ttm:role');
        frame.begin = TtmlParser.attrOf(attrs, 'begin');
        frame.end = TtmlParser.attrOf(attrs, 'end');
        stack.push(frame);
        i = gt + 1;
      } else {
        // 其它标签（<br/> 之类）直接跳过
        const gt: number = inner.indexOf('>', lt);
        if (gt < 0) {
          break;
        }
        i = gt + 1;
      }
    }
    flush();

    // 排掉空片段，但保留「只有空格」的（它们是词间间隔，影响排版宽度）
    const kept: LyricWord[] = [];
    for (let k = 0; k < out.length; k++) {
      if (out[k].text.length > 0) {
        kept.push(out[k]);
      }
    }
    if (kept.length === 0 && inner.length > 0) {
      const only: LyricWord = new LyricWord();
      only.text = TtmlParser.decode(TtmlParser.stripTags(inner));
      kept.push(only);
    }
    return kept;
  }

  /**
   * 解析 TTML 时间：`"30.866"` / `"1:00.637"` → 毫秒。
   */
  public static parseTime(raw: string): number {
    if (raw.length === 0) {
      return 0;
    }
    const parts: string[] = raw.split(':');
    let total: number = 0;
    for (let i = 0; i < parts.length; i++) {
      const v: number = Number.parseFloat(parts[i]);
      total = total * 60 + (Number.isNaN(v) ? 0 : v);
    }
    return Math.round(total * 1000);
  }

  /** 取属性值（按空格切 token，所以 `itunes:key` 这种带冒号的也能取到）。 */
  public static attrOf(attrs: string, name: string): string {
    const tokens: string[] = attrs.split(' ');
    for (let i = 0; i < tokens.length; i++) {
      const t: string = tokens[i].trim();
      const eq: number = t.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      if (t.substring(0, eq) !== name) {
        continue;
      }
      let v: string = t.substring(eq + 1);
      if (v.length >= 2) {
        const first: string = v.charAt(0);
        const last: string = v.charAt(v.length - 1);
        if ((first === '"' && last === '"') || (first === '\'' && last === '\'')) {
          v = v.substring(1, v.length - 1);
        }
      }
      return v;
    }
    return '';
  }

  /** 剥掉所有 XML 标签，只留文本。 */
  public static stripTags(xml: string): string {
    let out: string = '';
    let i: number = 0;
    while (i < xml.length) {
      const lt: number = xml.indexOf('<', i);
      if (lt < 0) {
        out += xml.substring(i);
        break;
      }
      out += xml.substring(i, lt);
      const gt: number = xml.indexOf('>', lt);
      if (gt < 0) {
        break;
      }
      i = gt + 1;
    }
    return out;
  }

  /** XML 实体反转义（&amp; 必须最后处理，否则会二次转义）。 */
  public static decode(s: string): string {
    if (s.indexOf('&') < 0) {
      return s;
    }
    let out: string = s;
    out = out.split('&lt;').join('<');
    out = out.split('&gt;').join('>');
    out = out.split('&quot;').join('"');
    out = out.split('&apos;').join('\'');
    out = out.split('&#39;').join('\'');
    out = out.split('&#x27;').join('\'');
    out = out.split('&#x2019;').join('’');
    out = out.split('&nbsp;').join(' ');
    out = out.split('&amp;').join('&');
    return out;
  }

  /**
   * 按标签名切出同级元素（不处理同名嵌套，TTML 里 `<div>`/`<p>`/`<text>` 都不嵌套）。
   */
  public static splitElements(xml: string, tag: string): XmlElement[] {
    const out: XmlElement[] = [];
    const open: string = '<' + tag;
    const close: string = '</' + tag + '>';
    let from: number = 0;
    while (from < xml.length) {
      let at: number = xml.indexOf(open, from);
      while (at >= 0) {
        const c: string = xml.charAt(at + open.length);
        if (c === '>' || c === ' ' || c === '\n' || c === '\t' || c === '\r') {
          break;
        }
        at = xml.indexOf(open, at + 1);
      }
      if (at < 0) {
        break;
      }
      const gt: number = xml.indexOf('>', at);
      if (gt < 0) {
        break;
      }
      const end: number = xml.indexOf(close, gt);
      if (end < 0) {
        break;
      }
      const el: XmlElement = new XmlElement();
      el.attrs = xml.substring(at + open.length, gt);
      el.inner = xml.substring(gt + 1, end);
      out.push(el);
      from = end + close.length;
    }
    return out;
  }
}

/**
 * Apple 歌词服务：拉取 + 解析 + 内存缓存。
 *
 * 调用方（播放器）只需要 `AppleLyrics.get(songId)`；404 / 没有歌词都返回 null。
 */
export class AppleLyrics {
  /** 已解析成功的歌词（进程内缓存，切歌来回切不重复请求）。 */
  private static cache: Map<string, AppleLyric> = new Map<string, AppleLyric>();
  /** 确认没有歌词的曲目（负缓存，避免每首歌都白请求两次）。 */
  private static missing: Set<string> = new Set<string>();
  /** single-flight：同一首歌的并发请求共用一个 Promise。 */
  private static inflight: Map<string, Promise<AppleLyric | null>> = new Map<string, Promise<AppleLyric | null>>();
  /**
   * 资料库曲目 id（`i.xxx`）→ 目录曲目 id（纯数字）的映射缓存。
   *
   * 2026-10-03 实测（这是「歌词页一片空白」的根因）：
   * 资料库同步下来的歌曲 src 是 `apple:i.1YBmpXPU718drxq` 这种**资料库 id**，
   * 而歌词接口 `/v1/catalog/{storefront}/songs/{id}/...` 只认**目录 id**
   * （`attributes.playParams.catalogId`，纯数字）。拿资料库 id 直接请求一律
   * 404 `40403 No related resources found for lyrics` —— 于是歌词静默为空。
   * 同一首歌实测：目录 id 1440841383 → syllable-lyrics 200 / TTML 24196 字符。
   * 反过来 `/v1/me/library/songs/{id}/lyrics` 是不存在的（400），只有 catalog 端点有歌词。
   */
  private static catalogIds: Map<string, string> = new Map<string, string>();
  /** 正在解析 catalogId 的请求（同样做 single-flight）。 */
  private static catalogInflight: Map<string, Promise<string>> = new Map<string, Promise<string>>();

  /**
   * 从 `SongItem.src`（形如 `apple:1624001324`）里取 Apple 曲目 id。
   *
   * @returns 曲目 id；不是 Apple 音源时返回空串。
   */
  public static songIdFromSrc(src: string): string {
    if (src.startsWith('apple:')) {
      return src.substring('apple:'.length);
    }
    return '';
  }

  /**
   * 取一首歌的歌词（优先逐词，404 自动降级到逐行）。
   *
   * @param songId Apple 曲目 id。
   * @returns 歌词；没有歌词或请求失败时返回 null。
   */
  public static get(songId: string): Promise<AppleLyric | null> {
    if (songId.length === 0) {
      return Promise.resolve(null);
    }
    const hit: AppleLyric | undefined = AppleLyrics.cache.get(songId);
    if (hit !== undefined) {
      return Promise.resolve(hit);
    }
    if (AppleLyrics.missing.has(songId)) {
      return Promise.resolve(null);
    }
    const running: Promise<AppleLyric | null> | undefined = AppleLyrics.inflight.get(songId);
    if (running !== undefined) {
      return running;
    }
    const task: Promise<AppleLyric | null> = AppleLyrics.doFetch(songId);
    AppleLyrics.inflight.set(songId, task);
    return task.then((r: AppleLyric | null) => {
      AppleLyrics.inflight.delete(songId);
      return r;
    }).catch((err: Error) => {
      AppleLyrics.inflight.delete(songId);
      Logger.warn(TAG, `get 失败 ${songId}: ${err.message}`);
      return null;
    });
  }

  /** 真正拉一次：先逐词，404 再逐行。 */
  private static async doFetch(songId: string): Promise<AppleLyric | null> {
    await AppleApi.ensureReady();
    // 资料库 id 必须先换成目录 id，否则歌词接口一律 404（见 catalogIds 的注释）。
    const catalogId: string = await AppleLyrics.resolveCatalogId(songId);
    if (catalogId.length === 0) {
      Logger.info(TAG, `拿不到目录 id，跳过歌词 ${songId}`);
      AppleLyrics.missing.add(songId);
      return null;
    }
    let ttml: string = await AppleLyrics.fetchTtml(catalogId, true);
    if (ttml.length === 0) {
      ttml = await AppleLyrics.fetchTtml(catalogId, false);
    }
    if (ttml.length === 0) {
      Logger.info(TAG, `没有歌词 ${songId}`);
      AppleLyrics.missing.add(songId);
      return null;
    }
    const lyric: AppleLyric = TtmlParser.parse(ttml, songId);
    if (lyric.isEmpty()) {
      AppleLyrics.missing.add(songId);
      return null;
    }
    AppleLyrics.cache.set(songId, lyric);
    return lyric;
  }

  /**
   * 资料库曲目 id（`i.xxx` 开头）→ 目录曲目 id（纯数字）；目录 id 原样返回。
   *
   * 带进程内缓存 + single-flight：同一首歌只在第一次进歌词页时多花一次请求，
   * 之后（包括来回切歌）都直接命中。
   */
  private static async resolveCatalogId(songId: string): Promise<string> {
    if (!songId.startsWith('i.')) {
      return songId;
    }
    const hit: string | undefined = AppleLyrics.catalogIds.get(songId);
    if (hit !== undefined) {
      return hit;
    }
    const running: Promise<string> | undefined = AppleLyrics.catalogInflight.get(songId);
    if (running !== undefined) {
      return running;
    }
    const task: Promise<string> = AppleApi.librarySongCatalogId(songId)
      .then((cid: string) => {
        if (cid.length > 0) {
          AppleLyrics.catalogIds.set(songId, cid);
        }
        AppleLyrics.catalogInflight.delete(songId);
        return cid;
      })
      .catch((err: Error) => {
        AppleLyrics.catalogInflight.delete(songId);
        Logger.warn(TAG, `catalogId 解析失败 ${songId}: ${err.message}`);
        return '';
      });
    AppleLyrics.catalogInflight.set(songId, task);
    return task;
  }

  /**
   * 拉 TTML 原文。
   *
   * @param songId **目录**曲目 id（纯数字）；资料库 id（`i.xxx`）会 404。
   * @param wordLevel true 请求 syllable-lyrics（逐词），false 请求 lyrics（逐行）。
   * @returns TTML 字符串；404 / 无歌词返回空串。
   */
  private static async fetchTtml(songId: string, wordLevel: boolean): Promise<string> {
    const kind: string = wordLevel ? 'syllable-lyrics' : 'lyrics';
    // storefront 必须用账号所在区（见文件头注释），跟歌曲原属哪个区无关
    const path: string = `/v1/catalog/${AppleApi.getStorefront()}/songs/${songId}/${kind}?l=${AppleApi.langTag()}`;
    const txt: string = await AppleApi.ampGetOptional(path);
    if (txt.length === 0) {
      return '';
    }
    try {
      const root: Record<string, Object> = JSON.parse(txt) as Record<string, Object>;
      const data: Object[] = (root['data'] as Object[]) ?? [];
      if (data.length === 0) {
        return '';
      }
      const first: Record<string, Object> = data[0] as Record<string, Object>;
      const attrs: Record<string, Object> = (first['attributes'] as Record<string, Object>) ?? {};
      const ttml: string = (attrs['ttml'] as string) ?? '';
      if (ttml.length > 0) {
        return ttml;
      }
      // 少数情况下是 ttmlLocalizations（多语言包），取第一个
      const locs: Record<string, Object> = (attrs['ttmlLocalizations'] as Record<string, Object>) ?? {};
      const keys: string[] = Object.keys(locs);
      for (let i = 0; i < keys.length; i++) {
        const v: string = (locs[keys[i]] as string) ?? '';
        if (v.length > 0) {
          return v;
        }
      }
      return '';
    } catch (err) {
      const e: Error = err as Error;
      Logger.warn(TAG, `TTML 解析失败 ${songId}: ${e.message}`);
      return '';
    }
  }

  /** 清掉某首歌的缓存（歌词源更新时用）。 */
  public static invalidate(songId: string): void {
    AppleLyrics.cache.delete(songId);
    AppleLyrics.missing.delete(songId);
    AppleLyrics.catalogIds.delete(songId);
  }

  /** 清空全部歌词缓存。 */
  public static clearCache(): void {
    AppleLyrics.cache.clear();
    AppleLyrics.missing.clear();
    AppleLyrics.catalogIds.clear();
  }
}
