using Dotbot.Server.Services;
using Microsoft.Agents.Core.Models;

namespace Dotbot.Server.Tests.Integration.TestDoubles;

internal sealed class NullConversationReferenceStore : IConversationReferenceStore
{
    public Task LoadAsync() => Task.CompletedTask;
    public void AddOrUpdate(string userObjectId, ConversationReference reference) { }
    public ConversationReference? Get(string userObjectId) => null;
}
