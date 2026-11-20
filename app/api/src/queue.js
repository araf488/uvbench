import { Queue, QueueEvents } from 'bullmq';
import IORedis from 'ioredis';
import { config } from './config.js';

export const connection = () => new IORedis(config.redisUrl, { maxRetriesPerRequest: null });

export const QUEUES = { chat: 'ai-chat', voice: 'ai-voice' };

let queues, events;
export function getQueues() {
  if (!queues) {
    const conn = connection();
    queues = {
      chat: new Queue(QUEUES.chat, { connection: conn }),
      voice: new Queue(QUEUES.voice, { connection: conn }),
    };
    events = {
      chat: new QueueEvents(QUEUES.chat, { connection: connection() }),
      voice: new QueueEvents(QUEUES.voice, { connection: connection() }),
    };
  }
  return { queues, events };
}

const jobOpts = { removeOnComplete: { age: 3600, count: 5000 }, removeOnFail: { age: 86400 }, attempts: 1 };

/** Enqueue an AI job and wait for its result. Throws {statusCode:503} when the backlog is too deep. */
export async function runAiJob(kind, data) {
  const { queues: q, events: e } = getQueues();
  const counts = await q[kind].getJobCounts('waiting', 'active', 'delayed');
  const backlog = counts.waiting + counts.delayed;
  if (backlog >= config.aiQueueLimit) {
    const err = new Error(`AI ${kind} queue is full (${backlog} waiting)`);
    err.statusCode = 503;
    throw err;
  }
  const job = await q[kind].add(kind, data, jobOpts);
  return job.waitUntilFinished(e[kind], config.aiTimeoutMs);
}
