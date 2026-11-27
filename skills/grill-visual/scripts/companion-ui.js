// grill-visual の frame の操作。client.js(通信)の後に読み込まれる。
// 選んだ案・案への補足・別案(その他)・要素へのコメント・微調整・画面全体への指示を 1 本の指示文にまとめ、
// 右上の操作バーからプレビュー・コピーさせる。同じ文をサーバーへ送り、state_dir/instruction.md に書かせる
// (コピーし忘れても AI が読める。貼った文が主で、ファイルは補い)。
(function () {
  // ===== 純関数(bun:test で確かめる。tests/grill-visual) =====

  function formatTweakValue(value, unit) {
    return unit ? `${value}${unit}` : String(value);
  }

  // 選択か別案のある問いを数える。firstUnanswered は未回答の最初の問いの位置(無ければ -1)
  function countAnswered(groups) {
    const answered = (g) => g.answers.length > 0 || Boolean(g.other);
    return {
      answered: groups.filter(answered).length,
      total: groups.length,
      firstUnanswered: groups.findIndex((g) => !answered(g)),
    };
  }

  // 指示文の形: 何をしてほしいかの 1 段落 + XML タグで区切った決定・コメント・微調整・全体への指示。
  // タグで区切るのは、ユーザーが書いた自由文と指示の構造を AI が取り違えないため(Claude のプロンプティングの推奨)。
  // 案の ID・推奨かどうか・CSS 変数名も載せ、AI が画面のファイルと突き合わせられるようにする。
  // groups: [{ question, answers: [{ label, choice, recommended?, addendum? }], other }]
  // comments: [{ n?, target, text }](n は画面のピンの番号)、tweaks: [{ name, label, from, to }](変えたものだけ)
  const esc = (v) => String(v).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

  function buildInstruction({ title = '', screen = '', groups = [], comments = [], tweaks = [], globalNote = '' }) {
    const answered = groups.filter((g) => g.answers.length || g.other);
    const written = comments.filter((c) => c.text);
    const count = answered.length + written.length + tweaks.length + (globalNote ? 1 : 0);
    if (count === 0) return { count, text: '(まだ何も選んでいません)' };

    // 最初の段落は Claude Opus 5.5 のプロンプティングの指針に沿う:
    // - 貼った文は <pasted_content> として届き、ユーザー自身の言葉と読めるものだけが指示になるので、一人称で「私の決定」として書く
    // - Opus 5.5 はすぐ作業に入るので、先に画面のファイルを開いて案の中身を確かめるよう頼む
    // - 「〜しない」ではなく、出たタグごとに何をするかを具体的に書く(出ないタグは説明しない)
    const anyAddendum = groups.some((g) => g.answers.some((a) => a.addendum));
    const anyRecommended = groups.some((g) => g.answers.some((a) => a.recommended));
    const lead = [
      `私は grill-visual の画面${title ? `「${title}」` : ''}で、案を見比べて次のとおり決めました。`,
      screen ? '作業に入る前に <screen> のファイルを開き、選んだ案(id は data-choice)の中身を確かめてください。' : '',
      answered.length ? `<decisions> の <chosen>${groups.some((g) => g.other) ? ' と <other>(どの案でもない別案)' : ''}は確定です。` : '',
      anyRecommended ? 'recommended="true" は、推奨として最初から選ばれていた案を私がそのまま残したものです。' : '',
      anyAddendum ? '<addendum> は、その案を選んだうえで変えてほしい所です。' : '',
      written.length ? '<comments> は、target の要素への私の指摘です。' : '',
      tweaks.length ? '<tweaks> は、画面のスライダーで調整した見た目です。to の値を、その CSS 変数(var)の値として反映してください。' : '',
      globalNote ? '<overall> は、画面全体への私の指示です。' : '',
      groups.length > answered.length ? 'unanswered="true" の問いはまだ決めていないので、必要になったら推奨を付けて聞いてください。' : '',
      'これらをすべて反映して、次の作業に進めてください。',
    ].join('');
    const parts = [lead];
    if (screen) parts.push(`<screen>${esc(screen)}</screen>`);
    if (groups.length) {
      const qs = groups.map((g) => {
        const name = `name="${esc(g.question)}"`;
        if (!g.answers.length && !g.other) return `<question ${name} unanswered="true"/>`;
        const lines = [];
        for (const a of g.answers) {
          lines.push(`<chosen id="${esc(a.choice ?? '')}"${a.recommended ? ' recommended="true"' : ''}>${esc(a.label)}</chosen>`);
          if (a.addendum) lines.push(`<addendum to="${esc(a.choice ?? '')}">${esc(a.addendum)}</addendum>`);
        }
        if (g.other) lines.push(`<other>${esc(g.other)}</other>`);
        return `<question ${name}>\n${lines.join('\n')}\n</question>`;
      });
      parts.push(`<decisions>\n${qs.join('\n')}\n</decisions>`);
    }
    if (written.length) {
      parts.push(`<comments>\n${written.map((c, i) => `<comment n="${c.n ?? i + 1}" target="${esc(c.target)}">${esc(c.text)}</comment>`).join('\n')}\n</comments>`);
    }
    if (tweaks.length) {
      parts.push(`<tweaks>\n${tweaks.map((t) => `<tweak var="${esc(t.name)}" label="${esc(t.label)}" from="${esc(t.from)}" to="${esc(t.to)}"/>`).join('\n')}\n</tweaks>`);
    }
    if (globalNote) parts.push(`<overall>${esc(globalNote)}</overall>`);
    return { count, text: parts.join('\n\n') };
  }

  if (typeof module !== 'undefined' && module.exports) {
    module.exports = { buildInstruction, countAnswered, formatTweakValue };
  }
  if (typeof window === 'undefined') return;

  // ===== ブラウザ =====
  // full document の画面には frame が無いので何もしない
  const root = document.getElementById('frame-content');
  if (!root) return;

  const $ = (id) => document.getElementById(id);
  const isUi = (el) => Boolean(el.closest('[data-gv-ui]'));
  const isTyping = (el) => el instanceof HTMLElement && el.matches('input, textarea, select, [contenteditable="true"]');
  // Safari は変換確定の Enter を isComposing: false で送るので keyCode 229 も見る
  const isImeComposing = (e) => e.isComposing || e.keyCode === 229;
  const groups = () => [...root.querySelectorAll('.pick-list, .pick-grid')];
  const itemsOf = (group) => [...group.querySelectorAll('.pick, .pick-tile')].filter((el) => el.closest('.pick-list, .pick-grid') === group);
  const isMulti = (group) => group.dataset.multiselect !== undefined;
  const groupKey = (group, i) => group.dataset.question || `#${i}`;

  // frame が足した部品(推奨の印・補足欄)を除いた文字
  function textOf(el) {
    if (!el) return '';
    const clone = el.cloneNode(true);
    clone.querySelectorAll('[data-gv-ui]').forEach((n) => n.remove());
    return clone.textContent.replace(/\s+/g, ' ').trim();
  }
  const labelOf = (item) => textOf(item.querySelector('h3') || item.querySelector('p')) || textOf(item);
  const questionOf = (group) => group.dataset.question || group.querySelector('[data-choice]')?.dataset.choice || '';

  // ===== 保存(再読み込み・同じ画面の書き直しで入力を消さない) =====
  const storeKey = `grill-visual:${window.GRILL_SCREEN || location.pathname}`;
  function load() {
    try { return JSON.parse(sessionStorage.getItem(storeKey)) || null; } catch (e) { return null; }
  }
  const state = load() || { touched: false, selected: null, addenda: {}, others: {}, comments: [], tweaks: {}, globalNote: '', tweaksOpen: null };
  function save() {
    try { sessionStorage.setItem(storeKey, JSON.stringify(state)); } catch (e) { /* 保存できなくても操作は続ける */ }
  }

  // ===== 推奨の印・補足欄・別案の欄・キーボード =====
  function decorate() {
    groups().forEach((group, gi) => {
      const multi = isMulti(group);
      group.setAttribute('role', multi ? 'group' : 'radiogroup');
      if (questionOf(group)) group.setAttribute('aria-label', questionOf(group));
      itemsOf(group).forEach((item) => {
        item.tabIndex = 0;
        item.setAttribute('role', multi ? 'checkbox' : 'radio');
        if (item.dataset.recommended !== undefined && !item.querySelector('.gv-badge')) {
          const badge = document.createElement('span');
          badge.className = 'gv-badge';
          badge.dataset.gvUi = '';
          badge.textContent = '推奨';
          (item.querySelector('h3') || item).appendChild(badge);
        }
        if (!item.querySelector('.gv-addendum')) {
          const input = document.createElement('input');
          input.type = 'text';
          input.className = 'gv-addendum';
          input.dataset.gvUi = '';
          input.placeholder = 'この案への補足(選んだまま、ここだけ変えたい所)';
          input.setAttribute('aria-label', `${labelOf(item)} への補足`);
          const key = `${groupKey(group, gi)}:${item.dataset.choice}`;
          input.value = state.addenda[key] || '';
          input.addEventListener('input', () => { state.addenda[key] = input.value; changed(); });
          (item.querySelector('.pick-body') || item).appendChild(input);
        }
      });
      if (!group.querySelector('.other-note')) {
        // 1 つだけ選ぶ問いでは「その他」も選択肢の 1 つ(別案)。書くとほかの選択を外し、選択肢を押すと消える
        const input = document.createElement('input');
        input.type = 'text';
        input.className = 'other-note';
        input.dataset.gvUi = '';
        input.placeholder = multi ? 'その他の指示' : 'その他(どれでもない別案)';
        input.setAttribute('aria-label', `${questionOf(group)} その他の指示`.trim());
        input.value = state.others[groupKey(group, gi)] || '';
        input.addEventListener('input', () => {
          const filled = input.value.trim() !== '';
          if (!multi && filled) itemsOf(group).forEach((el) => el.classList.remove('selected'));
          state.others[groupKey(group, gi)] = input.value;
          changed();
        });
        group.appendChild(input);
      }
    });
  }

  // 補足欄の中の操作で、案の選択を切り替えない
  root.addEventListener('click', (e) => { if (e.target.closest('.gv-addendum')) e.stopPropagation(); }, true);

  function restoreSelection() {
    if (state.selected) {
      groups().forEach((group, gi) => {
        const chosen = state.selected[groupKey(group, gi)];
        if (!chosen) return;
        itemsOf(group).forEach((item) => item.classList.toggle('selected', chosen.includes(item.dataset.choice)));
      });
      return;
    }
    // 初めて開いた画面だけ、data-recommended の案を選んだ状態にする
    groups().forEach((group) => {
      const rec = itemsOf(group).filter((item) => item.dataset.recommended !== undefined);
      if (!rec.length || itemsOf(group).some((item) => item.classList.contains('selected'))) return;
      (isMulti(group) ? rec : rec.slice(0, 1)).forEach((item) => item.classList.add('selected'));
    });
  }

  function snapshotSelection() {
    const selected = {};
    groups().forEach((group, gi) => {
      selected[groupKey(group, gi)] = itemsOf(group).filter((el) => el.classList.contains('selected')).map((el) => el.dataset.choice);
    });
    state.selected = selected;
  }

  // 案を押したときの選択。1 つだけ選ぶ問いでは同じ問いの選択を外し、別案の欄に書いた文も消す
  function choose(el) {
    const group = el.closest('.pick-list, .pick-grid');
    if (!group) return;
    if (isMulti(group)) {
      el.classList.toggle('selected');
    } else {
      itemsOf(group).forEach((o) => o.classList.remove('selected'));
      el.classList.add('selected');
      const note = group.querySelector('.other-note');
      if (note && note.value) {
        note.value = '';
        state.others[groupKey(group, groups().indexOf(group))] = '';
      }
    }
    changed();
  }
  document.addEventListener('click', (e) => {
    const item = e.target instanceof HTMLElement && e.target.closest('.pick, .pick-tile');
    if (item && root.contains(item) && !isUi(e.target)) choose(item);
  });

  document.addEventListener('keydown', (e) => {
    if (isImeComposing(e) || e.metaKey || e.ctrlKey || e.altKey) return;
    const item = e.target instanceof HTMLElement && e.target.closest('.pick, .pick-tile');
    if (item && e.target === item && (e.key === 'Enter' || e.key === ' ')) {
      e.preventDefault();
      item.click();
      return;
    }
    if (item && e.target === item && ['ArrowDown', 'ArrowRight', 'ArrowUp', 'ArrowLeft'].includes(e.key)) {
      const list = itemsOf(item.closest('.pick-list, .pick-grid'));
      const step = e.key === 'ArrowDown' || e.key === 'ArrowRight' ? 1 : -1;
      e.preventDefault();
      list[(list.indexOf(item) + step + list.length) % list.length].focus();
      return;
    }
    if (e.key === 'Escape') { closeAll(); return; }
    if (isTyping(e.target)) return;
    if (e.key === 'c') { setCommenting(!commenting); return; }
    // 数字キー: フォーカスのある問い(無ければ未回答の最初の問い)の n 番目の案を選ぶ
    if (/^[1-9]$/.test(e.key)) {
      const focused = document.activeElement && document.activeElement.closest('.pick-list, .pick-grid');
      // フォーカスが問いの外で、全問に答えてあるときは何もしない(推奨の初期選択を黙って変えない)
      const group = focused || groups()[countAnswered(collectGroups()).firstUnanswered];
      const target = group && itemsOf(group)[Number(e.key) - 1];
      if (target) { target.click(); target.focus(); }
    }
  });

  // ===== 要素へのコメント(ピン) =====
  let commenting = false;
  let hoverTarget = null;
  const pinLayer = document.createElement('div');
  pinLayer.className = 'gv-pin-layer';
  pinLayer.dataset.gvUi = '';
  root.appendChild(pinLayer);

  // root からの子の位置の列。画面を書き直しても同じ要素を指せる範囲で戻す
  function pathOf(el) {
    const path = [];
    for (let n = el; n && n !== root; n = n.parentElement) path.unshift([...n.parentElement.children].indexOf(n));
    return path;
  }
  function fromPath(path) {
    let n = root;
    for (const i of path) n = n && n.children[i];
    return n && n !== root ? n : null;
  }

  // 指示文に載せる「どの要素か」。案の中なら案の名前を先に置く
  function describe(el) {
    const item = el.closest('.pick, .pick-tile');
    const own = el.getAttribute('aria-label') || el.getAttribute('alt') || el.getAttribute('title') || textOf(el);
    const snippet = own ? `「${own.length > 24 ? `${own.slice(0, 24)}…` : own}」` : `${el.tagName.toLowerCase()} 要素`;
    if (!item) return snippet;
    const name = `案「${labelOf(item)}」`;
    return el === item || el.closest('h3') ? name : `${name}の${snippet}`;
  }

  function setCommenting(on) {
    commenting = on;
    document.body.classList.toggle('gv-commenting', on);
    $('gv-comment-toggle').setAttribute('aria-pressed', String(on));
    $('gv-comment-hint').hidden = !on;
    if (!on && hoverTarget) { hoverTarget.classList.remove('gv-hover-target'); hoverTarget = null; }
  }

  root.addEventListener('mouseover', (e) => {
    if (!commenting || isUi(e.target)) return;
    if (hoverTarget) hoverTarget.classList.remove('gv-hover-target');
    hoverTarget = e.target;
    hoverTarget.classList.add('gv-hover-target');
  });

  // capture で先に取り、コメント中のクリックで案の選択を変えない
  document.addEventListener('click', (e) => {
    if (!commenting || !root.contains(e.target) || isUi(e.target)) return;
    e.preventDefault();
    e.stopPropagation();
    // 本文の余白(root 自身)は指す要素が無いので置かない
    if (e.target === root) return;
    e.target.classList.remove('gv-hover-target');
    const rect = e.target.getBoundingClientRect();
    state.comments.push({
      path: pathOf(e.target),
      fx: rect.width ? (e.clientX - rect.left) / rect.width : 0,
      fy: rect.height ? (e.clientY - rect.top) / rect.height : 0,
      target: describe(e.target),
      text: '',
    });
    setCommenting(false);
    changed();
    openEditor(state.comments.length - 1);
  }, true);

  // 画面の書き直しで指す要素が無くなったコメントは、開く手段が無いので落とす
  function dropLostComments() {
    const kept = state.comments.filter((c) => c.path.length && fromPath(c.path));
    if (kept.length !== state.comments.length) { state.comments = kept; save(); }
  }
  const pinOf = (i) => pinLayer.querySelector(`[data-index="${i}"]`);
  function placePins() {
    pinLayer.replaceChildren();
    const base = root.getBoundingClientRect();
    state.comments.forEach((c, i) => {
      const el = fromPath(c.path);
      if (!el) return;
      const r = el.getBoundingClientRect();
      const pin = document.createElement('button');
      pin.type = 'button';
      pin.className = 'gv-pin';
      pin.textContent = String(i + 1);
      pin.dataset.index = String(i);
      pin.dataset.empty = String(!c.text.trim());
      pin.style.left = `${r.left - base.left + r.width * c.fx}px`;
      pin.style.top = `${r.top - base.top + r.height * c.fy}px`;
      pin.setAttribute('aria-label', `コメント ${i + 1}: ${c.target}`);
      pin.title = c.text || c.target;
      pin.addEventListener('click', () => openEditor(i));
      pinLayer.appendChild(pin);
    });
  }

  let editing = -1;
  function openEditor(i) {
    editing = i;
    const editor = $('gv-comment-editor');
    const pin = pinOf(i);
    editor.hidden = false;
    $('gv-comment-target').textContent = `${i + 1}. ${state.comments[i].target}`;
    const text = $('gv-comment-text');
    text.value = state.comments[i].text;
    if (pin) {
      const r = pin.getBoundingClientRect();
      editor.style.left = `${Math.max(16, Math.min(r.right + 8, window.innerWidth - editor.offsetWidth - 16))}px`;
      editor.style.top = `${Math.max(16, Math.min(r.top, window.innerHeight - editor.offsetHeight - 16))}px`;
    }
    text.focus();
  }
  function closeEditor() {
    const pin = pinOf(editing);
    $('gv-comment-editor').hidden = true;
    editing = -1;
    if (pin) pin.focus();
  }
  $('gv-comment-text').addEventListener('input', (e) => {
    if (editing < 0) return;
    state.comments[editing].text = e.target.value;
    changed();
  });
  $('gv-comment-text').addEventListener('keydown', (e) => {
    if (isImeComposing(e)) return;
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); closeEditor(); }
  });
  $('gv-comment-done').addEventListener('click', closeEditor);
  $('gv-comment-delete').addEventListener('click', () => {
    if (editing >= 0) state.comments.splice(editing, 1);
    $('gv-comment-editor').hidden = true;
    editing = -1;
    changed();
  });
  $('gv-comment-toggle').addEventListener('click', () => setCommenting(!commenting));

  // ===== 微調整(画面が [data-tweaks] の中に置いた input を右のパネルへ移す) =====
  const tweakInputs = [...root.querySelectorAll('[data-tweaks] input, [data-tweaks] select')].filter((el) => el.name);
  const tweakList = $('gv-tweak-list');
  const tweakRows = tweakInputs.map((input) => {
    const def = input.value;
    const unit = input.dataset.unit || '';
    const label = input.dataset.label || input.name;
    const scopes = () => (input.dataset.scope ? [...root.querySelectorAll(input.dataset.scope)] : [root]);
    const row = document.createElement('div');
    row.className = 'gv-tweak';
    const head = document.createElement('div');
    head.className = 'gv-tweak-head';
    const name = document.createElement('label');
    name.textContent = label;
    input.id = input.id || `gv-tweak-${input.name.replace(/[^\w-]/g, '')}`;
    name.htmlFor = input.id;
    const value = document.createElement('output');
    value.htmlFor = input.id;
    const reset = document.createElement('button');
    reset.type = 'button';
    reset.className = 'gv-link';
    reset.textContent = '戻す';
    reset.setAttribute('aria-label', `${label}を ${formatTweakValue(def, unit)} に戻す`);
    head.append(name, value, reset);
    row.append(head, input);
    tweakList.appendChild(row);
    if (state.tweaks[input.name] !== undefined) input.value = state.tweaks[input.name];
    const apply = () => {
      const v = formatTweakValue(input.value, unit);
      scopes().forEach((el) => el.style.setProperty(input.name, v));
      value.textContent = v;
      reset.hidden = input.value === def;
    };
    input.addEventListener('input', () => {
      apply();
      if (input.value === def) delete state.tweaks[input.name];
      else state.tweaks[input.name] = input.value;
      changed();
    });
    reset.addEventListener('click', () => { input.value = def; input.dispatchEvent(new Event('input')); });
    apply();
    return { name: input.name, label, from: () => formatTweakValue(def, unit), to: () => formatTweakValue(input.value, unit), dirty: () => input.value !== def, reset: () => reset.click() };
  });
  root.querySelectorAll('[data-tweaks]').forEach((el) => { el.hidden = true; });
  $('gv-tweak-reset').addEventListener('click', () => tweakRows.forEach((t) => t.dirty() && t.reset()));
  function setTweaksOpen(open) {
    state.tweaksOpen = open;
    const shown = open && tweakRows.length > 0;
    document.body.classList.toggle('gv-tweaks-open', shown);
    $('gv-tweaks').hidden = !shown;
    $('gv-tweak-toggle').setAttribute('aria-pressed', String(open));
    save();
    requestAnimationFrame(placePins);
  }
  // 頭をつかんで動かす。位置は画面ごとに覚え、窓の外へは出さない(狭い画面では下に固定)
  const panel = $('gv-tweaks');
  function placePanel(left, top) {
    const maxLeft = window.innerWidth - panel.offsetWidth - 8;
    const maxTop = window.innerHeight - 48;
    panel.style.left = `${Math.max(8, Math.min(left, maxLeft))}px`;
    panel.style.top = `${Math.max(8, Math.min(top, maxTop))}px`;
    panel.style.right = 'auto';
  }
  $('gv-tweaks').querySelector('.gv-tweaks-head').addEventListener('pointerdown', (e) => {
    if (e.button !== 0 || e.target.closest('button') || window.innerWidth <= 720) return;
    const start = panel.getBoundingClientRect();
    const dx = e.clientX - start.left;
    const dy = e.clientY - start.top;
    const head = e.currentTarget;
    head.setPointerCapture(e.pointerId);
    panel.classList.add('gv-dragging');
    const move = (ev) => placePanel(ev.clientX - dx, ev.clientY - dy);
    const up = () => {
      head.removeEventListener('pointermove', move);
      panel.classList.remove('gv-dragging');
      const r = panel.getBoundingClientRect();
      state.tweaksPos = { left: r.left, top: r.top };
      save();
    };
    head.addEventListener('pointermove', move);
    head.addEventListener('pointerup', up, { once: true });
    head.addEventListener('pointercancel', up, { once: true });
  });
  if (state.tweaksPos) requestAnimationFrame(() => placePanel(state.tweaksPos.left, state.tweaksPos.top));
  window.addEventListener('resize', () => {
    if (state.tweaksPos && !panel.hidden) { const r = panel.getBoundingClientRect(); placePanel(r.left, r.top); }
  });
  $('gv-tweak-toggle').hidden = tweakRows.length === 0;
  $('gv-tweak-toggle').addEventListener('click', () => setTweaksOpen(!state.tweaksOpen));
  $('gv-tweak-close').addEventListener('click', () => setTweaksOpen(false));

  // ===== 指示文 =====
  function collectGroups() {
    return groups().map((group, gi) => ({
      question: questionOf(group),
      answers: itemsOf(group).filter((el) => el.classList.contains('selected')).map((el) => ({
        label: labelOf(el),
        choice: el.dataset.choice || '',
        recommended: el.dataset.recommended !== undefined,
        addendum: (state.addenda[`${groupKey(group, gi)}:${el.dataset.choice}`] || '').trim(),
      })),
      other: (group.querySelector('.other-note')?.value || '').trim(),
    }));
  }
  function instruction() {
    return buildInstruction({
      title: textOf(root.querySelector('h2')),
      screen: window.GRILL_SCREEN || '',
      groups: collectGroups(),
      comments: state.comments.map((c, i) => ({ n: i + 1, target: c.target, text: c.text.trim() })),
      tweaks: tweakRows.filter((t) => t.dirty()).map((t) => ({ name: t.name, label: t.label, from: t.from(), to: t.to() })),
      globalNote: state.globalNote.trim(),
    });
  }

  $('gv-global-note').value = state.globalNote;
  $('gv-global-note').addEventListener('input', (e) => { state.globalNote = e.target.value; changed(); });

  function setPreview(open) {
    $('gv-preview').hidden = !open;
    $('gv-preview-toggle').setAttribute('aria-expanded', String(open));
    if (open) $('gv-preview-text').textContent = instruction().text;
  }
  $('gv-preview-toggle').addEventListener('click', () => setPreview($('gv-preview').hidden));
  // 外を押したら閉じる(山形・パネルの中の操作は除く)
  document.addEventListener('pointerdown', (e) => {
    if ($('gv-preview').hidden || e.target.closest('#gv-preview, #gv-preview-toggle')) return;
    setPreview(false);
  });

  async function copy(button) {
    // コピーは推奨のまま決めたという意思表示なので、触ったものとして AI にも送る
    if (!state.touched) { state.touched = true; save(); send(); }
    const { count, text } = instruction();
    await navigator.clipboard.writeText(text);
    const label = button.querySelector('span');
    const original = label.dataset.label || label.textContent;
    label.dataset.label = original;
    label.textContent = `コピーしました(${count} 件)`;
    setTimeout(() => { label.textContent = original; }, 2000);
  }
  $('gv-copy').addEventListener('click', (e) => copy(e.currentTarget));

  function closeAll() {
    if (editing >= 0) closeEditor();
    else if (commenting) setCommenting(false);
    else if (!$('gv-preview').hidden) { setPreview(false); $('gv-preview-toggle').focus(); }
  }

  // 未回答の問いを示し、押すとそこへ移る
  let firstUnanswered = -1;
  function updateProgress(collected) {
    const count = countAnswered(collected);
    firstUnanswered = count.firstUnanswered;
    const button = $('gv-progress');
    button.hidden = count.total === 0;
    button.textContent = `${count.answered} / ${count.total} 問`;
    button.dataset.done = String(count.answered === count.total);
    button.setAttribute('aria-label', count.answered === count.total
      ? `${count.total} 問すべて回答済み`
      : `${count.total} 問中 ${count.answered} 問に回答。押すと未回答の問いへ移る`);
  }
  $('gv-progress').addEventListener('click', () => {
    const target = groups()[firstUnanswered];
    if (!target) return;
    target.scrollIntoView({ behavior: 'smooth', block: 'center' });
    itemsOf(target)[0]?.focus({ preventScroll: true });
  });

  function syncItems() {
    groups().forEach((group) => {
      itemsOf(group).forEach((item) => {
        const on = item.classList.contains('selected');
        item.setAttribute('aria-checked', String(on));
        const addendum = item.querySelector('.gv-addendum');
        if (addendum) addendum.hidden = !on;
      });
      const note = group.querySelector('.other-note');
      if (note) note.classList.toggle('selected', note.value.trim() !== '');
    });
  }

  // AI へ送るのは、ユーザーが触ってから(推奨の初期選択だけで「選びました」と読ませない)
  let sendTimer = null;
  function send() {
    if (!state.touched || !window.grillVisual) return;
    clearTimeout(sendTimer);
    sendTimer = setTimeout(() => window.grillVisual.sendInstruction(window.GRILL_SCREEN || '', instruction().text), 400);
  }

  function refresh() {
    syncItems();
    updateProgress(collectGroups());
    placePins();
    if (!$('gv-preview').hidden) $('gv-preview-text').textContent = instruction().text;
  }

  function changed() {
    state.touched = true;
    snapshotSelection();
    save();
    refresh();
    send();
  }

  dropLostComments();
  decorate();
  restoreSelection();
  // パネルは本文の上に浮くので、最初は右の余白に収まるときだけ開く(本文を隠さない)。以後は開閉を覚える
  setTweaksOpen(state.tweaksOpen ?? window.innerWidth - root.getBoundingClientRect().right >= 300 + 32);
  refresh();
  send();
  window.addEventListener('resize', placePins);
  window.addEventListener('load', placePins);
})();
