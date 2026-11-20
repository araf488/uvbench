'use client';
import { useRef, useState } from 'react';

export default function Assistant() {
  const [text, setText] = useState('');
  const [log, setLog] = useState('');
  const [busy, setBusy] = useState(false);
  const [recording, setRecording] = useState(false);
  const [audioUrl, setAudioUrl] = useState(null);
  const rec = useRef(null);

  const add = (line) => setLog((l) => `${l}${line}\n`);

  async function ask(e) {
    e.preventDefault();
    if (!text.trim()) return;
    setBusy(true); add(`You: ${text}`);
    const res = await fetch('/api/ai/ask', {
      method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ question: text }),
    });
    const out = await res.json();
    add(res.ok ? `AI (${out.timings.totalMs} ms): ${out.answer}` : `Error: ${out.error}`);
    setText(''); setBusy(false);
  }

  async function toggleVoice() {
    if (recording) { rec.current.stop(); return; }
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    const mr = new MediaRecorder(stream);
    const chunks = [];
    mr.ondataavailable = (ev) => chunks.push(ev.data);
    mr.onstop = async () => {
      stream.getTracks().forEach((t) => t.stop());
      setRecording(false); setBusy(true);
      const form = new FormData();
      form.append('file', new Blob(chunks, { type: mr.mimeType }), 'voice.webm');
      const res = await fetch('/api/ai/voice', { method: 'POST', body: form });
      const out = await res.json();
      if (res.ok) {
        add(`You (voice): ${out.transcript}`);
        add(`AI (${out.timings.totalMs} ms): ${out.answer}`);
        setAudioUrl(out.audioUrl);
      } else add(`Error: ${out.error}`);
      setBusy(false);
    };
    rec.current = mr; mr.start(); setRecording(true);
  }

  return (
    <>
      <h1>AI assistant</h1>
      <p className="muted">Self-hosted speech-to-text, AI search and chat, and text-to-speech. No external AI APIs.</p>
      <div className="log">{log || 'Ask a question or record a voice message.'}</div>
      <form onSubmit={ask}>
        <textarea rows={2} value={text} onChange={(e) => setText(e.target.value)} placeholder="Type a question" />
        <button disabled={busy}>Ask</button>{' '}
        <button type="button" onClick={toggleVoice} disabled={busy && !recording}>
          {recording ? 'Stop & send' : 'Record voice'}
        </button>
      </form>
      {audioUrl && <audio src={audioUrl} controls autoPlay />}
    </>
  );
}
