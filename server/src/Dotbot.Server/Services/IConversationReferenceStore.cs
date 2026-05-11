using Microsoft.Agents.Core.Models;

namespace Dotbot.Server.Services;

public interface IConversationReferenceStore
{
    Task LoadAsync();
    void AddOrUpdate(string userObjectId, ConversationReference reference);
    ConversationReference? Get(string userObjectId);
}
