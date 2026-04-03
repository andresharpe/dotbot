---
name: implement-telegram-bot
description: Implement Telegram bot interactions with command handlers, message parsing, and inline keyboards for conversational interfaces
auto_invoke: true
---

# Implement Telegram Bot

Guide for building Telegram bot functionality using Telegram.Bot library.

## When to Use

- Creating bot commands and handlers
- Parsing user messages and responses
- Building interactive keyboards
- Sending notifications and messages
- Managing conversation state

## Bot Setup

```csharp
var botClient = new TelegramBotClient(botToken);
var receiverOptions = new ReceiverOptions
{
    AllowedUpdates = Array.Empty<UpdateType>() // Receive all update types
};

botClient.StartReceiving(
    updateHandler: HandleUpdateAsync,
    pollingErrorHandler: HandlePollingErrorAsync,
    receiverOptions: receiverOptions);
```

## Command Handling

```csharp
private async Task HandleUpdateAsync(ITelegramBotClient botClient, Update update, CancellationToken cancellationToken)
{
    if (update.Message is not { } message)
        return;
    
    if (message.Text is not { } messageText)
        return;
    
    var chatId = message.Chat.Id;
    
    if (messageText.StartsWith("/"))
    {
        await HandleCommand(botClient, chatId, messageText, cancellationToken);
    }
    else
    {
        await HandleMessage(botClient, chatId, messageText, cancellationToken);
    }
}

private async Task HandleCommand(ITelegramBotClient botClient, long chatId, string command, CancellationToken cancellationToken)
{
    var parts = command.Split(' ', 2);
    var cmd = parts[0].ToLower();
    var args = parts.Length > 1 ? parts[1] : string.Empty;
    
    switch (cmd)
    {
        case "/start":
            await botClient.SendTextMessageAsync(chatId, "Welcome!", cancellationToken: cancellationToken);
            break;
        case "/help":
            await SendHelp(botClient, chatId, cancellationToken);
            break;
        // ... more commands
    }
}
```

## Inline Keyboards

```csharp
// Quick reply buttons
var keyboard = new InlineKeyboardMarkup(new[]
{
    new[]
    {
        InlineKeyboardButton.WithCallbackData("Option A", "callback_a"),
        InlineKeyboardButton.WithCallbackData("Option B", "callback_b")
    },
    new[]
    {
        InlineKeyboardButton.WithCallbackData("Cancel", "callback_cancel")
    }
});

await botClient.SendTextMessageAsync(
    chatId: chatId,
    text: "Choose an option:",
    replyMarkup: keyboard,
    cancellationToken: cancellationToken);
```

## Callback Query Handling

```csharp
private async Task HandleCallbackQuery(ITelegramBotClient botClient, CallbackQuery callbackQuery, CancellationToken cancellationToken)
{
    var chatId = callbackQuery.Message.Chat.Id;
    var data = callbackQuery.Data;
    
    switch (data)
    {
        case "callback_a":
            await botClient.AnswerCallbackQueryAsync(callbackQuery.Id, "You selected A", cancellationToken: cancellationToken);
            await botClient.EditMessageTextAsync(chatId, callbackQuery.Message.MessageId, "Option A selected", cancellationToken: cancellationToken);
            break;
        // ... more cases
    }
}
```

## Message Formatting

Telegram supports Markdown and HTML:

```csharp
// Markdown
await botClient.SendTextMessageAsync(
    chatId: chatId,
    text: "*Bold* _italic_ `code`",
    parseMode: ParseMode.MarkdownV2,
    cancellationToken: cancellationToken);

// HTML
await botClient.SendTextMessageAsync(
    chatId: chatId,
    text: "<b>Bold</b> <i>italic</i> <code>code</code>",
    parseMode: ParseMode.Html,
    cancellationToken: cancellationToken);
```

## Best Practices

- **Validate chat ID** - Only respond to authorized users
- **Error handling** - Catch and log all exceptions
- **Rate limiting** - Respect Telegram's limits (30 messages/second)
- **Message length** - Max 4096 characters, split if needed
- **State management** - Track conversation context per user
- **Async/await** - All bot operations are async

## Common Patterns

### Long-running operations
```csharp
await botClient.SendChatActionAsync(chatId, ChatAction.Typing, cancellationToken: cancellationToken);
// ... perform operation
await botClient.SendTextMessageAsync(chatId, result, cancellationToken: cancellationToken);
```

### Error recovery
```csharp
try
{
    await botClient.SendTextMessageAsync(chatId, message, cancellationToken: cancellationToken);
}
catch (ApiRequestException ex) when (ex.ErrorCode == 403)
{
    // User blocked bot - remove from subscribers
}
```

## Common Pitfalls

- ❌ Not handling callback queries
- ❌ Forgetting to answer callback queries (spinner keeps spinning)
- ❌ Sending too many messages too quickly
- ❌ Not escaping special characters in Markdown
- ❌ Not validating user authorization
- ❌ Blocking async operations

## Checklist

- [ ] Bot token configured securely
- [ ] Command handlers implemented
- [ ] Callback query handlers implemented
- [ ] Error handling in place
- [ ] User authorization checked
- [ ] Message formatting works correctly
- [ ] Inline keyboards tested
- [ ] Rate limiting considered
