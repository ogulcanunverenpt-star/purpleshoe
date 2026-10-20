'use strict';

const crypto = require('crypto');

const TICKET_TTL_MS = 60_000;
const tickets = new Map();

function hashTicket(ticket) {
  return crypto.createHash('sha256').update(ticket).digest('hex');
}

function removeExpiredTickets() {
  const now = Date.now();
  for (const [ticketHash, record] of tickets) {
    if (record.expiresAt <= now) tickets.delete(ticketHash);
  }
}

function issueMatrixHandoffTicket(session) {
  removeExpiredTickets();
  const ticket = crypto.randomBytes(32).toString('base64url');
  tickets.set(hashTicket(ticket), {
    ...session,
    expiresAt: Date.now() + TICKET_TTL_MS
  });
  return { ticket, expiresInSeconds: TICKET_TTL_MS / 1000 };
}

function redeemMatrixHandoffTicket(ticket) {
  if (typeof ticket !== 'string' || ticket.length < 32 || ticket.length > 128) return null;
  removeExpiredTickets();
  const ticketHash = hashTicket(ticket);
  const record = tickets.get(ticketHash);
  if (!record) return null;
  tickets.delete(ticketHash);
  return {
    baseUrl: record.baseUrl,
    userId: record.userId,
    accessToken: record.accessToken,
    deviceId: record.deviceId
  };
}

const cleanupTimer = setInterval(removeExpiredTickets, 10_000);
cleanupTimer.unref();

module.exports = {
  issueMatrixHandoffTicket,
  redeemMatrixHandoffTicket
};
