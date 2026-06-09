using System.Text.Json;
using Dotbot.Server.Models;
using Dotbot.Server.Models.Envelope;
using Dotbot.Server.Validation;

namespace Dotbot.Server.Services;

// Assembles the SPEC-029 envelope wire shape at read time from the minimal stored
// blobs: the immutable template (question), the instance (envelope identifiers +
// recipients), and the ResponseRecordV2(s) (flat answer + responder fields).
// agreesWithFirst is derived here, never stored.
//
// The storage layer (ResponseRecordV2 flat fields) is deliberately decoupled
// from the wire layer (AnswerDto / ResponderDto). The assembler is the single
// read-time composer that bridges them; wire and storage evolve independently.
public sealed class EnvelopeAssembler
{
    private readonly ITemplateStorageService _templates;

    public EnvelopeAssembler(ITemplateStorageService templates)
    {
        _templates = templates;
    }

    /// <summary>Question record (envelope + question + recipients) for GET instance.</summary>
    public async Task<EnvelopeMessage> AssembleInstanceRecordAsync(QuestionInstance instance)
    {
        var question = await _templates.GetTemplateRawAsync(instance.ProjectId, instance.QuestionId, instance.QuestionVersion);
        return new EnvelopeMessage
        {
            Envelope = BuildInstanceEnvelope(instance),
            Question = question,
            Recipients = instance.SentTo,
        };
    }

    /// <summary>
    /// Full response records for an instance, ordered by submittedAt ascending, each
    /// with agreesWithFirst computed (null on the earliest).
    /// </summary>
    public async Task<List<EnvelopeMessage>> AssembleResponsesAsync(QuestionInstance instance, IEnumerable<ResponseRecordV2> responses)
    {
        var question = await _templates.GetTemplateRawAsync(instance.ProjectId, instance.QuestionId, instance.QuestionVersion);

        // Ascending by SubmittedAt - index 0 is the earliest (first-write-wins).
        var sorted = responses.OrderBy(r => r.SubmittedAt).ToList();
        var firstDecision = sorted.Count > 0 ? sorted[0].ApprovalDecision : null;

        var list = new List<EnvelopeMessage>(sorted.Count);
        for (var i = 0; i < sorted.Count; i++)
        {
            bool? agrees = i == 0 || firstDecision is null
                ? null
                : string.Equals(sorted[i].ApprovalDecision, firstDecision, StringComparison.Ordinal);
            list.Add(BuildResponseMessage(instance, question, sorted[i], agrees));
        }
        return list;
    }

    /// <summary>Single assembled response record (used for POST echoes if needed).</summary>
    public EnvelopeMessage BuildResponseMessage(QuestionInstance instance, JsonElement? question, ResponseRecordV2 response, bool? agreesWithFirst)
    {
        var envelope = BuildInstanceEnvelope(instance);
        envelope.ResponseId = response.ResponseId;
        envelope.SubmittedAt = Timestamps.FormatUtc(response.SubmittedAt);
        envelope.AnsweredVia = response.AnsweredVia;
        envelope.AgreesWithFirst = agreesWithFirst;

        return new EnvelopeMessage
        {
            Envelope = envelope,
            Question = question,
            Answer = MapAnswer(response),
            Responder = MapResponder(response),
        };
    }

    // Map flat storage fields onto the wire AnswerDto. Status is always
    // "submitted" on the wire - it is a wire-only acknowledgement and is
    // intentionally not persisted on the blob.
    private static AnswerDto MapAnswer(ResponseRecordV2 r) => new()
    {
        SelectedOptionId      = r.SelectedOptionId,
        SelectedKey           = r.SelectedKey,
        SelectedOptionTitle   = r.SelectedOptionTitle,
        FreeText              = r.FreeText,
        ApprovalDecision      = r.ApprovalDecision,
        Comment               = r.Comment,
        ReviewedAttachmentIds = r.ReviewedAttachmentIds,
        RankedItems           = r.RankedItems,
        Attachments           = r.Attachments,
        Status                = "submitted",
    };

    private static ResponderDto MapResponder(ResponseRecordV2 r) => new()
    {
        Email       = r.ResponderEmail,
        AadObjectId = r.ResponderAadObjectId,
    };

    private static EnvelopeDto BuildInstanceEnvelope(QuestionInstance instance) => new()
    {
        OutpostInstanceId = instance.OutpostInstanceId,
        TaskId = instance.TaskId,
        MothershipUrl = instance.MothershipUrl,
        QuestionInstanceId = instance.InstanceId,
        ProjectId = instance.ProjectId,
        SentAt = instance.SentAt is { } sentAt ? Timestamps.FormatUtc(sentAt) : null,
    };
}
