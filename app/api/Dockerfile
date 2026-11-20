FROM node:22-bookworm-slim
ENV NODE_ENV=production
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY src ./src
RUN mkdir -p /data/files && chown node:node /data/files
USER node
EXPOSE 4000 9400 9401
CMD ["node", "src/server.js"]
