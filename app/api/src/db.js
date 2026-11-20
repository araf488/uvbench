import pg from 'pg';
import { config } from './config.js';

export const pool = new pg.Pool({ ...config.pg, idleTimeoutMillis: 30000, connectionTimeoutMillis: 5000 });
pool.on('error', (err) => console.error('pg pool error', err.message));
