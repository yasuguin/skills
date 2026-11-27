// grill-visual の frame が作る「ターミナルに貼る指示文」の組み立てを確かめる。
// 形: 何をしてほしいかの 1 段落 + XML タグで区切った決定(問い・選んだ案・補足・別案)とコメント・微調整・全体への指示。
// タグで区切るのは、ユーザーが書いた自由文と指示の構造を AI が取り違えないため(Claude のプロンプティングの推奨)。
// 実行: bun test tests/grill-visual
import { describe, expect, test } from 'bun:test';
import { buildInstruction, countAnswered, formatTweakValue } from '../../skills/grill-visual/scripts/companion-ui.js';

const lead = (title) => buildInstruction({ title, groups: [{ question: 'Q', answers: [{ label: 'A', choice: 'a' }], other: '' }] }).text.split('\n\n')[0];

describe('buildInstruction', () => {
  test('最初の段落は、私(ユーザー)の決定として一人称で書き、何をしてほしいかを言う', () => {
    const text = lead('記事カードの見た目をどちらにするか');
    expect(text).toContain('私は grill-visual の画面「記事カードの見た目をどちらにするか」で');
    expect(text).toContain('<decisions>');
    expect(text).toContain('確定');
    expect(text).toContain('進めてください');
  });

  test('画面のファイルを <screen> で渡し、動く前に開いて案の中身を確かめるよう頼む(Opus 5.5 はすぐ作業に入るため)', () => {
    const { text } = buildInstruction({ screen: '/tmp/s1/content/card.html', groups: [{ question: 'Q', answers: [{ label: 'A', choice: 'a' }], other: '' }] });
    expect(text).toContain('<screen>/tmp/s1/content/card.html</screen>');
    expect(text.split('\n\n')[0]).toContain('作業に入る前に <screen> のファイルを開き');
  });

  test('出るタグごとに、どう扱うかを具体的に書く', () => {
    const { text } = buildInstruction({
      groups: [
        { question: 'Q1', answers: [{ label: 'A', choice: 'a', recommended: true, addendum: 'x' }], other: '' },
        { question: 'Q2', answers: [], other: '' },
      ],
      comments: [{ n: 1, target: 't', text: 'c' }],
      tweaks: [{ name: '--r', label: '角丸', from: '1px', to: '2px' }],
      globalNote: 'g',
    });
    const first = text.split('\n\n')[0];
    expect(first).toContain('recommended="true"');
    expect(first).toContain('to の値');
    expect(first).toContain('unanswered="true" の問いは');
    expect(first).toContain('推奨を付けて聞いてください');
  });

  test('出ないタグは最初の段落で説明しない', () => {
    const first = lead('T');
    expect(first).not.toContain('<tweaks>');
    expect(first).not.toContain('unanswered');
    expect(first).not.toContain('recommended');
  });

  test('問いごとに選んだ案を、案の ID・推奨かどうかと一緒に入れ子で書く', () => {
    const { text, count } = buildInstruction({
      groups: [
        { question: '見た目', answers: [{ label: 'B. 日付が先', choice: 'meta-first', addendum: '日付を小さく' }], other: '' },
        { question: '一覧に付けるもの', answers: [{ label: 'サムネイル', choice: 'thumb', recommended: true }, { label: 'タグ', choice: 'tag' }], other: '' },
      ],
    });
    expect(count).toBe(2);
    expect(text).toContain([
      '<decisions>',
      '<question name="見た目">',
      '<chosen id="meta-first">B. 日付が先</chosen>',
      '<addendum to="meta-first">日付を小さく</addendum>',
      '</question>',
      '<question name="一覧に付けるもの">',
      '<chosen id="thumb" recommended="true">サムネイル</chosen>',
      '<chosen id="tag">タグ</chosen>',
      '</question>',
      '</decisions>',
    ].join('\n'));
  });

  test('その他(別案)は <other> にし、答えていない問いは unanswered として残す', () => {
    const { text, count } = buildInstruction({
      groups: [
        { question: 'Q1', answers: [], other: '全部やめる' },
        { question: 'Q2', answers: [], other: '' },
      ],
    });
    expect(count).toBe(1);
    expect(text).toContain('<question name="Q1">\n<other>全部やめる</other>\n</question>');
    expect(text).toContain('<question name="Q2" unanswered="true"/>');
  });

  test('コメント・微調整・全体への指示を、それぞれのタグにまとめる', () => {
    const { text, count } = buildInstruction({
      groups: [{ question: 'Q', answers: [{ label: 'A', choice: 'a' }], other: '' }],
      comments: [{ n: 1, target: '案「A」の「保存」', text: '文字を小さく' }, { n: 2, target: '見出し', text: '' }],
      tweaks: [{ name: '--card-radius', label: '角丸', from: '8px', to: '12px' }],
      globalNote: '全体にもっと詰めて',
    });
    expect(count).toBe(4);
    expect(text).toContain('<comments>\n<comment n="1" target="案「A」の「保存」">文字を小さく</comment>\n</comments>');
    expect(text).not.toContain('見出し');
    expect(text).toContain('<tweaks>\n<tweak var="--card-radius" label="角丸" from="8px" to="12px"/>\n</tweaks>');
    expect(text).toContain('<overall>全体にもっと詰めて</overall>');
  });

  test('ユーザーの文の < & " はエスケープし、タグの構造を壊させない', () => {
    const { text } = buildInstruction({ groups: [{ question: 'a"b', answers: [], other: '<b> & </question>' }] });
    expect(text).toContain('<question name="a&quot;b">');
    expect(text).toContain('<other>&lt;b&gt; &amp; &lt;/question&gt;</other>');
  });

  test('何も答えていなければ、そう書くだけにする', () => {
    const { count, text } = buildInstruction({ groups: [{ question: 'Q', answers: [], other: '' }] });
    expect(count).toBe(0);
    expect(text).toBe('(まだ何も選んでいません)');
  });

  test('選択が無くても、微調整だけで指示になる', () => {
    const { text, count } = buildInstruction({ tweaks: [{ name: '--pad', label: '余白', from: '16px', to: '20px' }] });
    expect(count).toBe(1);
    expect(text).toContain('<tweak var="--pad" label="余白" from="16px" to="20px"/>');
  });
});

describe('countAnswered', () => {
  test('選択かその他のある問いを数える', () => {
    expect(countAnswered([
      { answers: [{ label: 'A' }], other: '' },
      { answers: [], other: 'x' },
      { answers: [], other: '' },
    ])).toEqual({ answered: 2, total: 3, firstUnanswered: 2 });
  });
});

describe('formatTweakValue', () => {
  test('単位を付ける', () => {
    expect(formatTweakValue('12', 'px')).toBe('12px');
    expect(formatTweakValue('#257de0', '')).toBe('#257de0');
  });
});
