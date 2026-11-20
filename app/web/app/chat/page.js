'use client';
import { useEffect, useRef, useState } from 'react';

export default function Chat() {
  const [msgs, setMsgs] = useState([]);
  const [text, setText] = useState('');
  const ws = useRef(null);

  useEffect(() => {
    const proto = location.protocol === 'https:' ? 'wss' : 'ws';
    const sock = new WebSocket(`${proto}://${location.host}/ws/chat?room=lobby`);
    sock.onmessage = (ev) => setMsgs((m) => [...m.slice(-99), JSON.parse(ev.data)]);
    ws.current = sock;
    return () => sock.close();
  }, []);

  function send(e) {
    e.preventDefault();
    if (text.trim() && ws.current?.readyState === 1) ws.current.send(text);
    setText('');
  }

  return (
    <>
      <h1>Live chat (lobby)</h1>
      <div className="log">{msgs.map((m) => `${new Date(m.at).toLocaleTimeString()}  ${m.body}`).join('\n')}</div>
      <form onSubmit={send}>
        <input value={text} onChange={(e) => setText(e.target.value)} placeholder="Say something" />
        <button>Send</button>
      </form>
    </>
  );
}
