// grill-visual の画面側の通信。サーバーとやり取りするのは次の 3 つだけ。
//   - GET /_gv/stream (SSE): 新しい画面ができたときの reload を受ける
//   - POST /_gv/event: クリックなどの操作を state_dir/events へ送る
//   - POST /_gv/instruction: frame が組み立てた指示文を state_dir/instruction.md へ送る(companion-ui.js が使う)
(function () {
  const MIN_RETRY_MS = 500;
  const MAX_RETRY_MS = 30000;
  // 切れてからこの時間たっても戻らなければ、止まったとみなして案内を出す
  const STOPPED_AFTER_MS = 15000;

  // 再接続の間隔は倍々に伸ばし、上限で止める
  function nextRetryDelay(current, max = MAX_RETRY_MS) {
    return Math.min(current * 2, max);
  }
  if (typeof module !== 'undefined' && module.exports) {
    module.exports = { nextRetryDelay, MIN_RETRY_MS, MAX_RETRY_MS };
  }
  if (typeof window === 'undefined') return;

  let source = null;
  let retryDelay = MIN_RETRY_MS;
  let retryTimer = null;
  let downSince = null;
  let everConnected = false;
  let stoppedShown = false;
  const queue = [];

  // frame の操作バーの状態表示(full document の画面には無い)
  function setStatus(state) {
    const el = document.querySelector('.status');
    if (!el) return;
    const map = {
      connecting: ['接続中…', 'var(--text-tertiary)'],
      connected: ['接続済み', 'var(--success)'],
      reconnecting: ['再接続中…', 'var(--warning)'],
      disconnected: ['切断', 'var(--error)'],
    };
    const [text, color] = map[state] || map.disconnected;
    el.textContent = text;
    // つながっている間は点だけ、それ以外は文字も出す(frame の CSS が data-state で切り替える)
    el.dataset.state = state;
    el.style.setProperty('--status-color', color);
  }

  // frame の有無に関わらず出せるよう、スタイルは自分で持つ
  function showStopped() {
    if (stoppedShown) return;
    stoppedShown = true;
    const el = document.createElement('div');
    el.id = 'gv-stopped';
    el.style.cssText = 'position:fixed;inset:0;z-index:99999;display:flex;align-items:center;justify-content:center;' +
      'padding:2rem;text-align:center;background:rgba(20,20,22,0.92);color:#f5f5f7;font-family:system-ui,sans-serif';
    el.innerHTML = '<div style="max-width:480px"><h2 style="margin:0 0 .5rem;font-weight:500">grill-visual は止まっています</h2>' +
      '<p style="margin:0;opacity:.85">エージェントにサーバーの再起動を頼み、新しい URL を開き直してください。</p></div>';
    if (document.body) document.body.appendChild(el);
  }

  function connect() {
    clearTimeout(retryTimer);
    setStatus(everConnected ? 'reconnecting' : 'connecting');
    source = new EventSource('/_gv/stream');
    source.onopen = () => {
      everConnected = true;
      downSince = null;
      retryDelay = MIN_RETRY_MS;
      setStatus('connected');
      while (queue.length) post('/_gv/event', queue.shift());
    };
    source.addEventListener('reload', () => window.location.reload());
    // EventSource は HTTP エラーで自動再接続しないので、自分で閉じて間隔を空けてつなぎ直す
    source.onerror = () => {
      source.close();
      if (downSince === null) downSince = Date.now();
      if (Date.now() - downSince >= STOPPED_AFTER_MS) { setStatus('disconnected'); showStopped(); } else setStatus('reconnecting');
      retryTimer = setTimeout(connect, retryDelay);
      retryDelay = nextRetryDelay(retryDelay);
    };
  }

  function post(url, body) {
    return fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) })
      .catch(() => { if (url === '/_gv/event') queue.push(body); });
  }

  // 選択肢(data-choice を持つ要素)のクリックを記録する
  document.addEventListener('click', (e) => {
    const target = e.target.closest && e.target.closest('[data-choice]');
    if (!target) return;
    post('/_gv/event', { type: 'click', text: target.textContent.trim(), choice: target.dataset.choice, id: target.id || null });
  });

  // full document の画面が自分で操作を送るための口
  window.grillVisual = {
    send: (event) => post('/_gv/event', { timestamp: Date.now(), ...event }),
    sendInstruction: (screen, text) => post('/_gv/instruction', { screen, text }),
  };
  connect();
})();
