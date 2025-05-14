# Zalo Integration for Chatwoot

This folder contains the implementation of the Zalo platform integration for Chatwoot.

## Features

- **QR Code Authentication**: Allows users to log in to Zalo by scanning a QR code
- **Real-time Messaging**: Connect to Zalo's WebSocket API through ActionCable
- **File Attachments**: Send and receive images and files
- **Friend Management**: Check friend status, send/accept friend requests
- **Multi-client Support**: Multiple Chatwoot users can connect to a single Zalo account

## Architecture

### Backend Components

1. **Channel::Zalo Model**: Represents a Zalo channel in Chatwoot
2. **WebsocketManagerService**: Manages the WebSocket connection to Zalo
3. **ClientService**: Handles API calls to Zalo
4. **EncryptionService**: Handles encryption/decryption of Zalo messages
5. **LoginService**: Manages the QR code login process
6. **ZaloChannel (ActionCable)**: Connects frontend clients to the Zalo WebSocket

### Frontend Components

1. **ZaloWebSocketClient**: JavaScript client for interacting with ActionCable
2. **ZaloQrCodeLogin**: Component for QR code authentication
3. **ZaloConversationView**: Component for displaying and sending messages
4. **ZaloAttachmentUploader**: Component for handling file attachments

## How Multi-client Works

The integration uses a single WebSocket connection to Zalo per account (as Zalo only allows one connection at a time), and distributes messages to multiple clients using ActionCable:

1. `WebsocketManagerService` maintains a single WebSocket connection to Zalo for each account
2. `ZaloChannel` (ActionCable) allows multiple frontend clients to subscribe
3. Messages received from Zalo are broadcast to all connected clients through ActionCable
4. When a client disconnects, it's tracked in `WebsocketManagerService`
5. The WebSocket connection is maintained as long as at least one client is connected, with auto-disconnect after a period of inactivity

## Development

### Adding New Features

1. Update the `ClientService` to implement new Zalo API endpoints
2. Add corresponding controller methods in `ZaloController`
3. Update frontend components as needed
4. Update routes in `config/routes/zalo.rb`

### Testing

1. Create a new Zalo channel in Chatwoot
2. Scan the QR code with your Zalo app
3. Test sending/receiving messages and files
4. Test friend management features

## Troubleshooting

### Common Issues

1. **WebSocket Connection Issues**: Check the Rails logs for WebSocket connection errors
2. **Authentication Issues**: Verify cookie_data and secret_key are valid
3. **File Upload Issues**: Check file size limits and temporary file paths

### Debug Logging

The integration includes comprehensive logging:
- `[Zalo::WebsocketManagerService]` - WebSocket connection logs
- `[Zalo::ClientService]` - API call logs
- `[Zalo::LoginService]` - QR code and authentication logs

## Limitations

1. Zalo only allows one active WebSocket connection per account
2. QR codes expire after 5 minutes
3. File size limits apply to uploads (20MB by default)
