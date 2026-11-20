// Stand-in for the AI services (LLM, embeddings, STT, TTS) so CI can test the API without models.
import http from 'node:http';
const json=(res,o)=>{res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify(o));};
http.createServer((req,res)=>{let b=[];req.on('data',c=>b.push(c));req.on('end',()=>{const body=Buffer.concat(b);
 if(req.url==='/v1/chat/completions'){setTimeout(()=>json(res,{choices:[{message:{content:'Mock answer.'}}],usage:{completion_tokens:12},timings:{prompt_ms:40,predicted_per_second:20}}),50);}
 else if(req.url==='/v1/embeddings'){const {input}=JSON.parse(body);json(res,{data:input.map((t,i)=>({embedding:Array.from({length:768},(_,k)=>Math.sin(t.length*(k+1)+i))}))});}
 else if(req.url==='/transcribe'){json(res,{text:'what is the warranty for a laptop',language:'en',duration:5,processing_seconds:1.2});}
 else if(req.url==='/synthesize'){res.writeHead(200,{'content-type':'audio/wav'});res.end(Buffer.alloc(1000));}
 else{res.writeHead(404);res.end();}});}).listen(58080);
