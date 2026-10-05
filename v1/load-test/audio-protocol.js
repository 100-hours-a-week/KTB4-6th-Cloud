// 새 녹음 세션만 시험한다. 기존 세션의 미확인 청크 복구는 별도 재연결 시험 대상이다.
export function prepareAudioStream(socket, onReady, onError) {
  let recovering = false;
  let ready = false;
  socket.on('message', function (raw) {
    try {
      const message = JSON.parse(raw);
      if (message.type === 'recovery.start') {
        if (recovering || ready || message.lastProcessedSequence !== 0) throw new Error('Unexpected recovery state');
        recovering = true;
        socket.send(JSON.stringify({ type: 'recovery.finished', lastSequence: 0 }));
      } else if (message.type === 'stream.ready') {
        if (!recovering || ready) throw new Error('Unexpected stream state');
        ready = true;
        onReady();
      } else if (message.type === 'ack') {
        if (!Number.isSafeInteger(message.seq) || message.seq < 0) throw new Error('Invalid acknowledgement');
      } else {
        throw new Error('Unexpected audio message');
      }
    } catch (_) { onError(); socket.close(); }
  });
  // HTTP 101だけではAIのデコーダ準備は完了していない。
  socket.setTimeout(function () {
    if (!ready) { onError(); socket.close(); }
  }, 60000);
}

export function audioFrame(audio, sequence) {
  // Java ByteBuffer.getLong()에 맞춰 8바이트 big endian 순번을 앞에 붙인다.
  if (!Number.isSafeInteger(sequence) || sequence < 1) throw new Error('Invalid audio sequence');
  const frame = new Uint8Array(8 + audio.byteLength);
  const header = new DataView(frame.buffer);
  header.setUint32(0, Math.floor(sequence / 4294967296), false);
  header.setUint32(4, sequence % 4294967296, false);
  frame.set(new Uint8Array(audio), 8);
  return frame.buffer;
}
