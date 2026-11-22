/**
 * Minimal Anthropic Messages API mock for verifying the reconstructed CLI
 * end-to-end without making external API calls.
 *
 * Run:  bun run scripts/mock-anthropic.ts
 * Then point the CLI at it:
 *   ANTHROPIC_BASE_URL=http://127.0.0.1:8787 ANTHROPIC_AUTH_TOKEN=test \
 *   bun run --preload ./compat/preload.ts ./src/entrypoints/cli.tsx \
 *     --bare -p "ping"
 */

const PORT = Number(process.env.MOCK_PORT ?? 8787);

const encoder = new TextEncoder();

function sse(event: string, data: unknown): Uint8Array {
  return encoder.encode(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
}

function messageBody(text: string) {
  return {
    id: 'msg_mock_0001',
    type: 'message',
    role: 'assistant',
    model: 'claude-mock',
    content: [{ type: 'text', text }],
    stop_reason: 'end_turn',
    stop_sequence: null,
    usage: { input_tokens: 7, output_tokens: 3 },
  };
}

Bun.serve({
  port: PORT,
  idleTimeout: 120,
  async fetch(req) {
    const url = new URL(req.url);

    if (req.method !== 'POST') {
      return new Response('mock anthropic server', { status: 200 });
    }

    if (url.pathname.endsWith('/count_tokens')) {
      return Response.json({ input_tokens: 7 });
    }

    if (!url.pathname.endsWith('/messages')) {
      return Response.json({ error: 'not found' }, { status: 404 });
    }

    const body = (await req.json()) as {
      stream?: boolean;
      model?: string;
      messages?: Array<{ role?: string; content?: unknown }>;
    };
    const model = body.model ?? 'claude-mock';
    let text = `pong (mock ${model})`;

    // Tool-use round trip: if the user asks for TOOLCALL and no tool_result
    // has been sent back yet, emit a Bash tool_use block.
    const messages = body.messages ?? [];
    const serialized = JSON.stringify(messages);
    const hasToolResult = serialized.includes('"tool_result"');
    const toolOutput = serialized.includes('mock-tool-ok') ? 'mock-tool-ok' : 'no-output';
    const lastUser = [...messages].reverse().find((m) => m.role === 'user');
    const wantsTool =
      JSON.stringify(lastUser ?? {}).includes('TOOLCALL') && !hasToolResult;

    if (wantsTool) {
      const toolUse = {
        type: 'tool_use' as const,
        id: 'toolu_mock_0001',
        name: 'Bash',
        input: { command: 'echo mock-tool-ok', description: 'Print mock marker' },
      };
      if (!body.stream) {
        return Response.json({
          ...messageBody(''),
          content: [toolUse],
          stop_reason: 'tool_use',
        });
      }
      const message = messageBody('');
      const stream = new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(
            sse('message_start', {
              type: 'message_start',
              message: { ...message, content: [], stop_reason: null },
            }),
          );
          controller.enqueue(
            sse('content_block_start', {
              type: 'content_block_start',
              index: 0,
              content_block: {
                type: 'tool_use',
                id: toolUse.id,
                name: toolUse.name,
                input: {},
              },
            }),
          );
          controller.enqueue(
            sse('content_block_delta', {
              type: 'content_block_delta',
              index: 0,
              delta: {
                type: 'input_json_delta',
                partial_json: JSON.stringify(toolUse.input),
              },
            }),
          );
          controller.enqueue(
            sse('content_block_stop', { type: 'content_block_stop', index: 0 }),
          );
          controller.enqueue(
            sse('message_delta', {
              type: 'message_delta',
              delta: { stop_reason: 'tool_use', stop_sequence: null },
              usage: { output_tokens: 5 },
            }),
          );
          controller.enqueue(sse('message_stop', { type: 'message_stop' }));
          controller.close();
        },
      });
      return new Response(stream, {
        headers: {
          'content-type': 'text/event-stream',
          'cache-control': 'no-cache',
          connection: 'keep-alive',
        },
      });
    }

    if (hasToolResult) {
      text = `pong-after-tool (${toolOutput})`;
    }

    if (!body.stream) {
      return Response.json(messageBody(text));
    }

    const message = messageBody(text);
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(
          sse('message_start', {
            type: 'message_start',
            message: { ...message, content: [], stop_reason: null },
          }),
        );
        controller.enqueue(
          sse('content_block_start', {
            type: 'content_block_start',
            index: 0,
            content_block: { type: 'text', text: '' },
          }),
        );
        controller.enqueue(
          sse('content_block_delta', {
            type: 'content_block_delta',
            index: 0,
            delta: { type: 'text_delta', text },
          }),
        );
        controller.enqueue(
          sse('content_block_stop', { type: 'content_block_stop', index: 0 }),
        );
        controller.enqueue(
          sse('message_delta', {
            type: 'message_delta',
            delta: { stop_reason: 'end_turn', stop_sequence: null },
            usage: { output_tokens: 3 },
          }),
        );
        controller.enqueue(sse('message_stop', { type: 'message_stop' }));
        controller.close();
      },
    });

    return new Response(stream, {
      headers: {
        'content-type': 'text/event-stream',
        'cache-control': 'no-cache',
        connection: 'keep-alive',
      },
    });
  },
});

console.log(`mock anthropic listening on http://127.0.0.1:${PORT}`);
