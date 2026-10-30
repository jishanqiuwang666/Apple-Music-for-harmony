/**
 * AI 歌词翻译（DeepSeek）
 *
 * 为什么需要它：实测 Apple 的歌词接口只对**极少数**歌曲提供 `<translation>` 层 ——
 * 中文歌常带 zh-Hans（简体替换用），而英文/韩文歌实测 8 首全部 `trans=[]`，
 * 也就是「官方压根没有中文翻译」。于是英文歌的译文行永远是空的。
 *
 * 这里补一条 AI 翻译通道：
 *   · 官方有翻译 → 用官方的（更准、有权威性）
 *   · 官方没有   → 用户主动点「译」时，把整首歌词一次性交给 DeepSeek 翻成简体中文
 *
 * 三条纪律：
 *  1. **整首一次请求**：逐行请求既慢又费钱（一首 40 行的歌就是 40 次调用）。
 *  2. **按歌缓存**：同一首歌只花一次钱；缓存按曲目 id 落在内存里（App 生命周期内有效）。
 *  3. **行数必须对齐**：返回数组长度与输入不一致就整体作废——宁可没有译文，
 *     也不能把第 3 行的译文错挂到第 5 行上（那是灾难性的观感）。
 */
import { http } from '@kit.NetworkKit';
import { Logger } from '../util/Logger';
import { AiTransConfig } from './AiTransConfig';

const TAG: string = 'AiLyricsTranslator';
const ENDPOINT: string = 'https://api.deepseek.com/chat/completions';
/** 凭据从 AiTransConfig 取（设置面板可改；未配置时用它内置的出厂 key）。 */
const MODEL: string = 'deepseek-chat';
const CONNECT_TIMEOUT_MS: number = 15000;
const READ_TIMEOUT_MS: number = 90000;

/** 系统提示词：只要译文，不要任何解释。 */
const SYSTEM_PROMPT: string = '你是专业的歌词译者。用户会给你一个 JSON 数组，里面是一首歌的逐行歌词。' +
  '请把每一行翻译成自然、简洁的简体中文，保持歌词的语感（不要逐字硬译，不要加注释或音译说明）。' +
  '只输出一个 JSON 对象：{"lines": ["第1行译文", "第2行译文", ...]}，' +
  'lines 的元素个数必须与输入数组**完全一致且顺序一一对应**。' +
  '若某行是纯音乐说明或无意义感叹（如 [Music]、oh、yeah），就输出简短中文或原样保留。' +
  '不要输出代码块标记，不要输出除这个 JSON 以外的任何字符。';

interface ChatMessage {
  role: string;
  content: string;
}

interface JsonFormat {
  type: string;
}

interface ChatBody {
  model: string;
  messages: ChatMessage[];
  temperature: number;
  max_tokens: number;
  stream: boolean;
  response_format: JsonFormat;
}

interface ChatChoice {
  message: ChatMessage;
}

interface ChatResp {
  choices: ChatChoice[];
}

interface TransLines {
  lines: string[];
}

export class AiLyricsTranslator {
  /** 曲目 id → 逐行译文（与传入的行数组等长、同序）。 */
  private static cache: Map<string, string[]> = new Map<string, string[]>();
  /** 正在翻译的请求（同一首歌并发点击只发一次请求）。 */
  private static inflight: Map<string, Promise<string[]>> = new Map<string, Promise<string[]>>();

  /** 是否已有缓存（换回同一首歌时可直接用，不再花钱）。 */
  public static cached(songId: string): string[] | undefined {
    return AiLyricsTranslator.cache.get(songId);
  }

  public static clearCache(): void {
    AiLyricsTranslator.cache.clear();
  }

  /**
   * 把整首歌词翻成简体中文。
   *
   * @param songId 曲目 id（缓存键）
   * @param lines  逐行原文（空行会被跳过，结果里对应位置是空串）
   * @returns 与 lines 等长的译文数组；失败时返回空数组
   */
  public static translate(songId: string, lines: string[]): Promise<string[]> {
    const hit: string[] | undefined = AiLyricsTranslator.cache.get(songId);
    if (hit !== undefined) {
      return Promise.resolve(hit);
    }
    const running: Promise<string[]> | undefined = AiLyricsTranslator.inflight.get(songId);
    if (running !== undefined) {
      return running;
    }
    const task: Promise<string[]> = AiLyricsTranslator.doTranslate(songId, lines);
    AiLyricsTranslator.inflight.set(songId, task);
    return task.then((r: string[]) => {
      AiLyricsTranslator.inflight.delete(songId);
      return r;
    }).catch((err: Error) => {
      AiLyricsTranslator.inflight.delete(songId);
      Logger.warn(TAG, `翻译失败 ${songId}: ${err.message}`);
      return [];
    });
  }

  private static async doTranslate(songId: string, lines: string[]): Promise<string[]> {
    // 只把「有内容的行」送去翻译，空行留在原位（省 token，也避免模型乱补空行）
    const indexes: number[] = [];
    const texts: string[] = [];
    for (let i = 0; i < lines.length; i++) {
      const t: string = lines[i].trim();
      if (t.length === 0) {
        continue;
      }
      indexes.push(i);
      texts.push(t);
    }
    if (texts.length === 0) {
      return [];
    }
    const out: string[] = [];
    for (let i = 0; i < lines.length; i++) {
      out.push('');
    }
    // 分块：一首歌通常 30~60 行，一次请求足够；超长（>80 行）按 80 行切块，避免输出被 max_tokens 截断
    const CHUNK: number = 80;
    for (let start = 0; start < texts.length; start += CHUNK) {
      const end: number = Math.min(texts.length, start + CHUNK);
      const slice: string[] = texts.slice(start, end);
      const part: string[] = await AiLyricsTranslator.requestChunk(slice);
      if (part.length !== slice.length) {
        Logger.warn(TAG, `块长不一致 ${part.length}/${slice.length}，放弃 ${songId}`);
        return [];
      }
      for (let k = 0; k < part.length; k++) {
        out[indexes[start + k]] = part[k];
      }
    }
    AiLyricsTranslator.cache.set(songId, out);
    Logger.info(TAG, `翻译完成 ${songId}: ${texts.length} 行`);
    return out;
  }

  /** 发一次请求，返回译文数组（长度不匹配时返回空数组）。 */
  private static async requestChunk(texts: string[]): Promise<string[]> {
    // 未配置 key 就直接返回空（开源版不带内置 key，见 AiTransConfig）
    if (!AiTransConfig.hasKey()) {
      Logger.warn(TAG, '未配置 AI 翻译 key，跳过翻译（设置 → AI 翻译 里填一个）');
      return [];
    }
    const body: ChatBody = {
      model: MODEL,
      messages: [
        { role: 'system', content: SYSTEM_PROMPT } as ChatMessage,
        { role: 'user', content: JSON.stringify(texts) } as ChatMessage
      ],
      temperature: 0.3,
      max_tokens: 8192,
      stream: false,
      response_format: { type: 'json_object' } as JsonFormat
    };
    const req: http.HttpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await req.request(ENDPOINT, {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ' + AiTransConfig.apiKey()
        },
        extraData: JSON.stringify(body),
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: READ_TIMEOUT_MS
      });
      const code: number = resp.responseCode;
      const raw: string = typeof resp.result === 'string' ? resp.result as string : '';
      if (code !== 200) {
        Logger.warn(TAG, `HTTP ${code}: ${raw.substring(0, 160)}`);
        return [];
      }
      const parsed: ChatResp = JSON.parse(raw) as ChatResp;
      if (parsed.choices === undefined || parsed.choices.length === 0) {
        return [];
      }
      const content: string = parsed.choices[0].message.content;
      return AiLyricsTranslator.extractLines(content, texts.length);
    } finally {
      req.destroy();
    }
  }

  /** 从模型回复里抠出 lines 数组（容忍 ```json 包裹）。 */
  private static extractLines(content: string, expect: number): string[] {
    let text: string = content.trim();
    const fence: number = text.indexOf('```');
    if (fence >= 0) {
      const start: number = text.indexOf('\n', fence);
      const close: number = text.lastIndexOf('```');
      if (start > 0 && close > start) {
        text = text.substring(start + 1, close).trim();
      }
    }
    const brace: number = text.indexOf('{');
    if (brace < 0) {
      return [];
    }
    try {
      const obj: TransLines = JSON.parse(text.substring(brace)) as TransLines;
      const arr: string[] = obj.lines;
      if (arr === undefined || arr.length !== expect) {
        Logger.warn(TAG, `行数不匹配 ${arr === undefined ? 'null' : arr.length}/${expect}`);
        return [];
      }
      return arr;
    } catch (err) {
      const e: Error = err as Error;
      Logger.warn(TAG, `译文 JSON 解析失败: ${e.message}`);
      return [];
    }
  }
}
