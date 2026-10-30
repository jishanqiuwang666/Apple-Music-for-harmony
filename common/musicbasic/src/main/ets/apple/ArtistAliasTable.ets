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

/**
 * 艺人名对照表：本地化名（中/日/韩） → Apple 目录里的规范名。
 *
 * 为什么需要：Apple 公开的目录搜索接口**只索引规范名**（例如方大同的规范名是
 * Khalil Fong），中文名不是可匹配别名 —— 实测搜「方大同」返回的是邓丽君、
 * 薛凯琪、Stevie Wonder 等相关艺人，本人反而不出现；换语言标签（l=zh-Hans-CN）
 * 返回完全相同的结果。官方 App 能搜到是因为它用的是另一套带别名索引、且会
 * 优先匹配「你自己的资料库」的搜索服务，不对外开放。
 *
 * 用法：搜索时若命中本表，就把规范名也搜一次并合并结果（见 AppleApi.search）。
 * 维护：遇到搜不到的艺人，把「中文名 = 规范名」发来加进这里即可。
 */
export class ArtistAliasTable {
  /** 归一化后的键值对：[本地化名, 目录规范名]。 */
  private static readonly PAIRS: string[][] = [
    // ── 华语：流行 / 摇滚 / 民谣 ──
    ['方大同', 'Khalil Fong'],
    ['周杰伦', 'Jay Chou'],
    ['邓紫棋', 'G.E.M.'],
    ['陈奕迅', 'Eason Chan'],
    ['林俊杰', 'JJ Lin'],
    ['王力宏', 'Leehom Wang'],
    ['陶喆', 'David Tao'],
    ['张学友', 'Jacky Cheung'],
    ['刘德华', 'Andy Lau'],
    ['郭富城', 'Aaron Kwok'],
    ['黎明', 'Leon Lai'],
    ['王菲', 'Faye Wong'],
    ['那英', 'Na Ying'],
    ['孙燕姿', 'Stefanie Sun'],
    ['蔡依林', 'Jolin Tsai'],
    ['莫文蔚', 'Karen Mok'],
    ['梁静茹', 'Fish Leong'],
    ['张惠妹', 'A-Mei'],
    ['田馥甄', 'Hebe Tien'],
    ['蔡健雅', 'Tanya Chua'],
    ['陈绮贞', 'Cheer Chen'],
    ['卢广仲', 'Crowd Lu'],
    ['吴青峰', 'Wu Qing-Feng'],
    ['韦礼安', 'WeiBird'],
    ['徐佳莹', 'Lala Hsu'],
    ['邓丽君', 'Teresa Teng'],
    ['张国荣', 'Leslie Cheung'],
    ['梅艳芳', 'Anita Mui'],
    ['罗大佑', 'Lo Ta-You'],
    ['李宗盛', 'Jonathan Lee'],
    ['周华健', 'Emil Chau'],
    ['任贤齐', 'Richie Jen'],
    ['光良', 'Michael Wong'],
    ['品冠', 'Victor Wong'],
    ['张信哲', 'Jeff Chang'],
    ['林宥嘉', 'Yoga Lin'],
    ['萧敬腾', 'Jam Hsiao'],
    ['杨宗纬', 'Aska Yang'],
    ['潘玮柏', 'Wilber Pan'],
    ['罗志祥', 'Show Lo'],
    ['李荣浩', 'Li Ronghao'],
    ['毛不易', 'Mao Buyi'],
    ['薛之谦', 'Joker Xue'],
    ['华晨宇', 'Hua Chenyu'],
    ['张杰', 'Jason Zhang'],
    ['汪峰', 'Wang Feng'],
    ['朴树', 'Pu Shu'],
    ['许嵩', 'Vae'],
    ['汪苏泷', 'Silence Wang'],
    ['周深', 'Zhou Shen'],
    ['李宇春', 'Chris Lee'],
    ['张靓颖', 'Jane Zhang'],
    ['郁可唯', 'Yisa Yu'],
    ['谭维维', 'Sitar Tan'],
    ['刘若英', 'Rene Liu'],
    ['许巍', 'Xu Wei'],
    ['郑钧', 'Zheng Jun'],
    ['朴炯植', 'Park Hyung Sik'],
    ['五月天', 'Mayday'],
    ['苏打绿', 'Sodagreen'],
    ['信乐团', 'Shin'],
    ['动力火车', 'Power Station'],
    ['飞儿乐团', 'F.I.R.'],
    ['Beyond', 'Beyond'],
    ['黑豹乐队', 'Black Panther'],
    ['痛仰', 'Miserable Faith'],
    ['新裤子', 'New Pants'],
    ['万能青年旅店', 'Omnipotent Youth Society'],
    ['陈粒', 'Chen Li'],
    ['赵雷', 'Zhao Lei'],
    ['宋冬野', 'Song Dongye'],
    ['李志', 'Li Zhi'],
    ['马頔', 'Ma Di'],
    ['好妹妹', 'Hao Mei Mei'],
    ['逃跑计划', 'Escape Plan'],
    ['鹿先森乐队', 'Mr. Deer'],
    ['王源', 'Wang Yuan'],
    ['王俊凯', 'Karry Wang'],
    ['易烊千玺', 'Jackson Yee'],
    ['蔡徐坤', 'KUN'],
    ['张艺兴', 'Lay Zhang'],
    ['鹿晗', 'Lu Han'],
    ['吴亦凡', 'Kris Wu'],
    ['刘柏辛', 'Lexie Liu'],
    ['袁娅维', 'Tia Ray'],
    ['吉克隽逸', 'Summer Jike'],
    ['阿肆', 'A Si'],
    ['房东的猫', 'Landlord Cat'],
    ['程璧', 'Cheng Bi'],
    ['李健', 'Li Jian'],
    ['孙楠', 'Sun Nan'],
    ['韩红', 'Han Hong'],
    ['腾格尔', 'Tengger'],
    ['腾格尔', 'Tengger'],
    ['降央卓玛', 'Jamyang Dolma'],
    ['痛痒乐队', 'Miserable Faith'],
    ['海龟先生', 'Mr. Sea Turtle'],
    ['二手玫瑰', 'Second Hand Rose'],
    ['C-BLOCK', 'C-BLOCK'],
    ['Higher Brothers', 'Higher Brothers'],
    ['蛋堡', 'Soft Lipa'],
    ['热狗', 'MC HotDog'],
    ['MC HotDog', 'MC HotDog'],
    ['马思唯', 'Masiwei'],
    ['王以太', 'Wang Yitai'],
    ['GAI', 'GAI'],
    ['艾热', 'AIR'],
    ['满舒克', 'Manshuke'],
    ['万妮达', 'Vinida'],
    ['陈慧娴', 'Priscilla Chan'],
    ['林忆莲', 'Sandy Lam'],
    ['叶倩文', 'Sally Yeh'],
    ['郑秀文', 'Sammi Cheng'],
    ['杨千嬅', 'Miriam Yeung'],
    ['容祖儿', 'Joey Yung'],
    ['谢霆锋', 'Nicholas Tse'],
    ['陈慧琳', 'Kelly Chen'],
    ['李克勤', 'Hacken Lee'],
    ['谭咏麟', 'Alan Tam'],
    ['林子祥', 'George Lam'],
    ['许冠杰', 'Sam Hui'],
    ['黄家驹', 'Wong Ka Kui'],
    ['陈百强', 'Danny Chan'],
    ['周慧敏', 'Vivian Chow'],
    ['王杰', 'Dave Wang'],
    ['巫启贤', 'Eric Moo'],
    ['张宇', 'Phil Chang'],
    ['庾澄庆', 'Harlem Yu'],
    ['伍佰', 'Wu Bai'],
    ['齐秦', 'Chyi Chin'],
    ['苏芮', 'Julie Sue'],
    ['蔡琴', 'Tsai Chin'],
    ['费玉清', 'Fei Yu-Ching'],
    ['凤飞飞', 'Feng Fei-Fei'],
    ['甄妮', 'Jenny Tseng'],
    ['娃娃', 'Wawa'],
    ['辛晓琪', 'Winnie Hsin'],
    ['万芳', 'Wan Fang'],
    ['黄韵玲', 'Kay Huang'],
    ['陈升', 'Bobby Chen'],
    ['陶晶莹', 'Matilda Tao'],
    ['黄立行', 'Stanley Huang'],
    ['F4', 'F4'],
    ['飞轮海', 'Fahrenheit'],
    ['S.H.E', 'S.H.E'],
    ['TWINS', 'Twins'],
    ['陈冠希', 'Edison Chen'],
    ['方力申', 'Alex Fong'],
    ['郑中基', 'Ronald Cheng'],
    ['张学友', 'Jacky Cheung'],
    ['侧田', 'Justin Lo'],
    ['卫兰', 'Janice Vidal'],
    ['关淑怡', 'Shirley Kwan'],
    ['彭羚', 'Cass Phang'],
    ['李蕙敏', 'Amanda Lee'],
    ['许志安', 'Andy Hui'],
    ['苏永康', 'William So'],
    ['张敬轩', 'Hins Cheung'],
    ['林一峰', 'Chet Lam'],
    ['at17', 'at17'],
    ['My Little Airport', 'My Little Airport'],
    ['麦浚龙', 'Juno Mak'],
    ['陈奕迅', 'Eason Chan'],
    ['何韵诗', 'Denise Ho'],
    ['黄耀明', 'Anthony Wong'],
    ['卢巧音', 'Candy Lo'],
    ['谢安琪', 'Kay Tse'],
    ['王菀之', 'Ivana Wong'],
    ['吴雨霏', 'Kary Ng'],
    ['周柏豪', 'Pakho Chau'],
    ['邓小巧', 'Tang Siu Hau'],
    ['林二汶', 'Eman Lam'],
    ['岑宁儿', 'Yoyo Sham'],
    ['黄妍', 'Cath Wong'],
    ['Serrini', 'Serrini'],
    ['林家谦', 'Terence Lam'],

    // ── 日本 ──
    ['椎名林檎', 'Sheena Ringo'],
    ['宇多田光', 'Utada'],
    ['宇多田ヒカル', 'Utada'],
    ['米津玄师', 'Kenshi Yonezu'],
    ['あいみょん', 'Aimyon'],
    ['星野源', 'Gen Hoshino'],
    ['安室奈美惠', 'Namie Amuro'],
    ['滨崎步', 'Ayumi Hamasaki'],
    ['幸田来未', 'Koda Kumi'],
    ['中岛美嘉', 'Mika Nakashima'],
    ['绚香', 'Ayaka'],
    ['生物股长', 'Ikimonogakari'],
    ['藤井风', 'Fujii Kaze'],
    ['山下达郎', 'Tatsuro Yamashita'],
    ['松任谷由实', 'Yumi Matsutoya'],
    ['坂本龙一', 'Ryuichi Sakamoto'],
    ['久石让', 'Joe Hisaishi'],
    ['喜多郎', 'Kitaro'],
    ['平原绫香', 'Ayaka Hirahara'],
    ['美空云雀', 'Hibari Misora'],
    ['五轮真弓', 'Mayumi Itsuwa'],
    ['中森明菜', 'Akina Nakamori'],
    ['松田圣子', 'Seiko Matsuda'],
    ['工藤静香', 'Shizuka Kudo'],
    ['槙原敬之', 'Noriyuki Makihara'],
    ['小田和正', 'Kazumasa Oda'],
    ['桑田佳祐', 'Keisuke Kuwata'],
    ['南方之星', 'Southern All Stars'],
    ['B\'z', 'B\'z'],
    ['Mr.Children', 'Mr.Children'],
    ['Spitz', 'Spitz'],
    ['柚子', 'Yuzu'],
    ['可苦可乐', 'Kobukuro'],
    ['色情涂鸦', 'Porno Graffitti'],
    ['岚', 'ARASHI'],
    ['关西杰尼斯8', 'Kanjani Eight'],
    ['东京事变', 'Tokyo Jihen'],
    ['X JAPAN', 'X JAPAN'],
    ['彩虹乐团', 'L\'Arc-en-Ciel'],
    ['凛冽时雨', 'Ling tosite sigure'],
    ['青苹果', 'Blue Hearts'],
    ['女王蜂', 'Ziyoou-vachi'],
    ['鱼韵', 'Sakanaction'],
    ['欢愉乐团', 'King Gnu'],
    ['胡子男', 'Official HIGE DANdism'],
    ['绿黄色社会', 'Ryokuoushoku Shakai'],
    ['ヨルシカ', 'Yorushika'],
    ['夜好性', 'ZUTOMAYO'],
    ['ずっと真夜中でいいのに。', 'ZUTOMAYO'],
    ['女王', 'Queen Bee'],
    ['爱缪', 'Aimyon'],
    ['凡人谱', 'Hitorie'],
    ['中村佳穗', 'Kaho Nakamura'],
    ['宇多田光', 'Utada Hikaru'],
    ['Reol', 'Reol'],
    ['三浦大知', 'Daichi Miura'],
    ['平原綾香', 'Ayaka Hirahara'],

    // ── 韩国 ──
    ['防弹少年团', 'BTS'],
    ['少女时代', 'Girls\' Generation'],
    ['东方神起', 'TVXQ!'],
    ['宝儿', 'BoA'],
    ['李孝利', 'Lee Hyori'],
    ['太妍', 'TAEYEON'],
    ['泰妍', 'TAEYEON'],
    ['白艺潾', 'Baek Yerin'],
    ['李遐怡', 'LEE HI'],
    ['脸红的思春期', 'BOL4'],
    ['金请夏', 'CHUNG HA'],
    ['宣美', 'SUNMI'],
    ['泫雅', 'HyunA'],
    ['华莎', 'HWASA'],
    ['泰民', 'TAEMIN'],
    ['伯贤', 'BAEKHYUN'],
    ['智旻', 'Jimin'],
    ['柾国', 'Jung Kook'],
    ['金泰亨', 'V'],
    ['闵玧其', 'SUGA'],
    ['郑号锡', 'j-hope'],
    ['金南俊', 'RM'],
    ['金硕珍', 'Jin'],
    ['朴智旻', 'Jimin'],
    ['田柾国', 'Jung Kook'],
    ['粉墨', 'BLACKPINK'],
    ['红贝贝', 'Red Velvet'],
    ['妈妈木', 'MAMAMOO'],
    ['十七', 'SEVENTEEN'],
    ['迷孩', 'Stray Kids'],
    ['艾斯帕', 'aespa'],
    ['一击', 'ITZY'],
    ['纽金斯', 'NewJeans'],
    ['乐塞拉芬', 'LE SSERAFIM'],
    ['爱我的', '(G)I-DLE'],
    ['魑', 'IVE'],
    ['EXO', 'EXO'],
    ['BIGBANG', 'BIGBANG'],
    ['2NE1', '2NE1'],
    ['SHINee', 'SHINee'],
    ['Super Junior', 'Super Junior'],
    ['WINNER', 'WINNER'],
    ['iKON', 'iKON'],
    ['AKMU', 'AKMU'],
    ['乐童音乐家', 'AKMU'],
    ['싸이', 'PSY'],
    ['鸟叔', 'PSY'],
    ['Epik High', 'Epik High'],
    ['Dynamic Duo', 'Dynamic Duo'],
    ['10cm', '10cm'],
    ['IU', 'IU'],
    ['아이유', 'IU'],
    ['ZICO', 'ZICO'],
    ['DEAN', 'DEAN'],
    ['Crush', 'Crush'],
    ['Heize', 'Heize'],
    ['脸红的思春期', 'Bolbbalgan4'],
    ['白艺潾', 'Baek Yerin'],

    // ── 西方古典 / 爵士（你库里大量出现的中文译名） ──
    ['格伦·古尔德', 'Glenn Gould'],
    ['格伦・古尔德', 'Glenn Gould'],
    ['马克思·李希特', 'Max Richter'],
    ['马克思・李希特', 'Max Richter'],
    ['内田光子', 'Mitsuko Uchida'],
    ['马友友', 'Yo-Yo Ma'],
    ['阿图尔·鲁宾斯坦', 'Arthur Rubinstein'],
    ['阿图尔・鲁宾斯坦', 'Arthur Rubinstein'],
    ['阿尔多·奇科里尼', 'Aldo Ciccolini'],
    ['阿尔多 · 奇科里尼', 'Aldo Ciccolini'],
    ['瓦尔特·吉泽金', 'Walter Gieseking'],
    ['瓦尔特 · 吉泽金', 'Walter Gieseking'],
    ['菲利普·格拉斯', 'Philip Glass'],
    ['菲利普・格拉斯', 'Philip Glass'],
    ['赫伯特·冯·卡拉扬', 'Herbert von Karajan'],
    ['卡拉扬', 'Herbert von Karajan'],
    ['柏林爱乐乐团', 'Berliner Philharmoniker'],
    ['维也纳爱乐乐团', 'Wiener Philharmoniker'],
    ['阿姆斯特丹皇家音乐厅管弦乐团', 'Royal Concertgebouw Orchestra'],
    ['贝多芬', 'Ludwig van Beethoven'],
    ['巴赫', 'Johann Sebastian Bach'],
    ['莫扎特', 'Wolfgang Amadeus Mozart'],
    ['肖邦', 'Frédéric Chopin'],
    ['德彪西', 'Claude Debussy'],
    ['拉赫玛尼诺夫', 'Sergei Rachmaninoff'],
    ['柴可夫斯基', 'Pyotr Ilyich Tchaikovsky'],
    ['舒伯特', 'Franz Schubert'],
    ['舒曼', 'Robert Schumann'],
    ['勃拉姆斯', 'Johannes Brahms'],
    ['李斯特', 'Franz Liszt'],
    ['瓦格纳', 'Richard Wagner'],
    ['马勒', 'Gustav Mahler'],
    ['布鲁克纳', 'Anton Bruckner'],
    ['西贝柳斯', 'Jean Sibelius'],
    ['萨蒂', 'Erik Satie'],
    ['拉威尔', 'Maurice Ravel'],
    ['普罗科菲耶夫', 'Sergei Prokofiev'],
    ['肖斯塔科维奇', 'Dmitri Shostakovich'],
    ['斯特拉文斯基', 'Igor Stravinsky'],
    ['门德尔松', 'Felix Mendelssohn'],
    ['亨德尔', 'George Frideric Handel'],
    ['维瓦尔第', 'Antonio Vivaldi'],
    ['帕赫贝尔', 'Johann Pachelbel'],
    ['格里格', 'Edvard Grieg'],
    ['德沃夏克', 'Antonín Dvořák'],
    ['阿尔沃·帕特', 'Arvo Pärt'],
    ['阿尔沃・帕特', 'Arvo Pärt'],
    ['霍洛维茨', 'Vladimir Horowitz'],
    ['里赫特', 'Sviatoslav Richter'],
    ['阿格里奇', 'Martha Argerich'],
    ['郎朗', 'Lang Lang'],
    ['王羽佳', 'Yuja Wang'],
    ['李云迪', 'Yundi Li'],
    ['傅聪', 'Fou Ts\'ong'],
    ['郑京和', 'Kyung Wha Chung'],
    ['安妮-索菲·穆特', 'Anne-Sophie Mutter'],
    ['伊扎克·帕尔曼', 'Itzhak Perlman'],
    ['马友友', 'Yo-Yo Ma'],
    ['卡萨尔斯', 'Pablo Casals'],
    ['杜普蕾', 'Jacqueline du Pré'],
    ['比尔·埃文斯', 'Bill Evans'],
    ['比尔・埃文斯', 'Bill Evans'],
    ['迈尔斯·戴维斯', 'Miles Davis'],
    ['迈尔斯・戴维斯', 'Miles Davis'],
    ['切特·贝克', 'Chet Baker'],
    ['切特・贝克', 'Chet Baker'],
    ['凯斯·杰瑞特', 'Keith Jarrett'],
    ['凯斯・杰瑞特', 'Keith Jarrett'],
    ['奥斯卡·彼得森', 'Oscar Peterson'],
    ['奥斯卡・彼得森', 'Oscar Peterson'],
    ['安东尼奥·卡洛斯·若宾', 'Antônio Carlos Jobim'],
    ['若昂·吉尔贝托', 'João Gilberto'],
    ['斯坦·盖茨', 'Stan Getz'],
    ['布拉德·梅尔道', 'Brad Mehldau'],
    ['布拉德・梅尔道', 'Brad Mehldau'],
    ['约翰·柯川', 'John Coltrane'],
    ['埃拉·菲茨杰拉德', 'Ella Fitzgerald'],
    ['路易斯·阿姆斯特朗', 'Louis Armstrong'],
    ['杜克·艾灵顿', 'Duke Ellington'],
    ['赫比·汉考克', 'Herbie Hancock'],
    ['帕特·麦席尼', 'Pat Metheny'],
    ['罗伊·哈格罗夫', 'Roy Hargrove'],
    ['坂本龙一', 'Ryuichi Sakamoto'],
    ['布赖恩·伊诺', 'Brian Eno'],
    ['布莱恩·伊诺', 'Brian Eno'],
    ['布莱恩・伊诺', 'Brian Eno'],
    ['奥拉佛·阿纳尔德斯', 'Ólafur Arnalds'],
    ['奥拉佛・阿纳尔德斯', 'Ólafur Arnalds'],
    ['尼尔斯·弗拉姆', 'Nils Frahm'],
    ['尼尔斯・弗拉姆', 'Nils Frahm'],
    ['哈妮雅·拉尼', 'Hania Rani'],
    ['哈妮雅・拉尼', 'Hania Rani'],
    ['乔珀·贝温', 'Joep Beving'],
    ['乔珀・贝温', 'Joep Beving'],
    ['平克·弗洛伊德', 'Pink Floyd'],
    ['平克・弗洛伊德', 'Pink Floyd'],
    ['披头士', 'The Beatles'],
    ['甲壳虫乐队', 'The Beatles'],
    ['滚石乐队', 'The Rolling Stones'],
    ['皇后乐队', 'Queen'],
    ['齐柏林飞艇', 'Led Zeppelin'],
    ['涅槃乐队', 'Nirvana'],
    ['电台司令', 'Radiohead'],
    ['酷玩乐队', 'Coldplay'],
    ['U2', 'U2'],
    ['鲍勃·迪伦', 'Bob Dylan'],
    ['大卫·鲍伊', 'David Bowie'],
    ['约翰·列侬', 'John Lennon'],
    ['保罗·麦卡特尼', 'Paul McCartney'],
    ['埃里克·克莱普顿', 'Eric Clapton'],
    ['史蒂维·旺德', 'Stevie Wonder'],
    ['迈克尔·杰克逊', 'Michael Jackson'],
    ['麦当娜', 'Madonna'],
    ['泰勒·斯威夫特', 'Taylor Swift'],
    ['碧昂丝', 'Beyoncé'],
    ['阿黛尔', 'Adele'],
    ['比莉·艾利什', 'Billie Eilish'],
    ['艾德·希兰', 'Ed Sheeran'],
    ['布鲁诺·马尔斯', 'Bruno Mars'],
    ['德雷克', 'Drake'],
    ['肯德里克·拉马尔', 'Kendrick Lamar'],
    ['弗兰克·奥申', 'Frank Ocean'],
    ['诺拉·琼斯', 'Norah Jones'],
    ['戴安娜·克瑞儿', 'Diana Krall'],
    ['恩雅', 'Enya'],
    ['雅尼', 'Yanni'],
    ['理查德·克莱德曼', 'Richard Clayderman'],
    ['班得瑞', 'Bandari']
  ];

  /** 归一化缓存（键：归一化后的本地化名 → 规范名）。 */
  private static table: Map<string, string> | undefined = undefined;

  /** 归一化：去空格与常见标点、转小写（与搜索侧的匹配口径一致）。 */
  private static normalize(text: string): string {
    let out: string = '';
    const lower: string = text.toLowerCase();
    for (let i = 0; i < lower.length; i++) {
      const c: string = lower.charAt(i);
      if (c === ' ' || c === '·' || c === '・' || c === '•' || c === '.' || c === ',' ||
        c === '·' || c === '-' || c === '_' || c === '(' || c === ')' || c === '/' ||
        c === '，' || c === '、' || c === '。' || c === '　') {
        continue;
      }
      out += c;
    }
    return out;
  }

  private static ensureTable(): Map<string, string> {
    if (ArtistAliasTable.table === undefined) {
      const map: Map<string, string> = new Map();
      for (let i = 0; i < ArtistAliasTable.PAIRS.length; i++) {
        const pair: string[] = ArtistAliasTable.PAIRS[i];
        if (pair.length < 2) {
          continue;
        }
        const key: string = ArtistAliasTable.normalize(pair[0]);
        if (key !== '' && !map.has(key)) {
          map.set(key, pair[1]);
        }
      }
      ArtistAliasTable.table = map;
    }
    return ArtistAliasTable.table;
  }

  /**
   * 查对照：输入本地化名，返回 Apple 目录里的规范名（没有则空串）。
   * @param term 用户输入的搜索词。
   */
  public static lookup(term: string): string {
    const key: string = ArtistAliasTable.normalize(term);
    if (key === '') {
      return '';
    }
    return ArtistAliasTable.ensureTable().get(key) ?? '';
  }

  /** 反向表缓存（键：归一化后的规范名 → 本地化名）。 */
  private static reverse: Map<string, string> | undefined = undefined;

  /**
   * 反向查对照：输入 Apple 的规范名（如 "Khalil Fong"），返回本地化名（如「方大同」）。
   *
   * 用途：Apple 的资料库艺人接口返回的是目录规范名，而本地歌曲表里存的是
   * 本地化名，两者对不上时用本方法换回本地名再匹配。
   *
   * @param canonical Apple 目录规范名。
   * @returns 本地化名；表里没有则空串。
   */
  public static localName(canonical: string): string {
    const key: string = ArtistAliasTable.normalize(canonical);
    if (key === '') {
      return '';
    }
    if (ArtistAliasTable.reverse === undefined) {
      const map: Map<string, string> = new Map();
      const pairs: string[][] = ArtistAliasTable.PAIRS;
      for (let i = 0; i < pairs.length; i++) {
        const pair: string[] = pairs[i];
        if (pair.length < 2) {
          continue;
        }
        const k: string = ArtistAliasTable.normalize(pair[1]);
        if (k !== '' && !map.has(k)) {
          map.set(k, pair[0]);
        }
      }
      ArtistAliasTable.reverse = map;
    }
    return ArtistAliasTable.reverse.get(key) ?? '';
  }

  /** @returns 表里收录的条数（设置页/诊断用）。 */
  public static size(): number {
    return ArtistAliasTable.ensureTable().size;
  }
}
