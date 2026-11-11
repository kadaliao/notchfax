import type { LineRow, LineView, MessageRow, MessageView } from "./types";

/** 以 viewer 的视角渲染线路：role / myAlias / peerAlias 随调用者不同而不同。 */
export function lineView(row: LineRow, viewerId: string): LineView {
  const isInitiator = row.initiator_id === viewerId;
  return {
    id: row.id,
    state: row.state,
    role: isInitiator ? "initiator" : "recipient",
    myAlias: (isInitiator ? row.initiator_alias : row.recipient_alias) ?? "",
    peerAlias: isInitiator ? row.recipient_alias : row.initiator_alias,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

export function messageView(row: MessageRow, viewerId: string): MessageView {
  const base = {
    id: row.id,
    lineId: row.line_id,
    from: row.sender_id === viewerId ? ("me" as const) : ("peer" as const),
    kind: row.kind,
    sentAt: row.sent_at,
  };
  if (row.kind === "image") {
    return { ...base, imageId: row.image_id ?? undefined, width: row.width ?? undefined, height: row.height ?? undefined };
  }
  return { ...base, text: row.text ?? "" };
}

export function peerOf(line: LineRow, viewerId: string): string | null {
  return line.initiator_id === viewerId ? line.recipient_id : line.initiator_id;
}

export function isParticipant(line: LineRow, deviceId: string): boolean {
  return line.initiator_id === deviceId || line.recipient_id === deviceId;
}
