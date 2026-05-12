using Microsoft.Extensions.Configuration;
using System.IO;

namespace Dotbot.Server.Services;

public class StoragePathResolver
{
    private readonly string _env;

    public StoragePathResolver(IConfiguration config)
    {
        _env = config["Environment:Name"] ?? "dev";
    }

    public string EnvironmentPrefix => _env;

    public string TemplatePath(string projectId, Guid questionId, int version)
        => $"{_env}/projects/{projectId}/questions/{questionId}/v{version}.json";

    public string InstancePath(string projectId, Guid instanceId)
        => $"{_env}/projects/{projectId}/instances/{instanceId}.json";

    public string ResponsePath(string projectId, Guid questionId, Guid instanceId, Guid responseId)
        => $"{_env}/projects/{projectId}/questions/{questionId}/instances/{instanceId}/responses/{responseId}.json";

    public string ResponsesPrefix(string projectId, Guid questionId, Guid instanceId)
        => $"{_env}/projects/{projectId}/questions/{questionId}/instances/{instanceId}/responses/";

    public string ResponsesForQuestionPrefix(string projectId, Guid questionId)
        => $"{_env}/projects/{projectId}/questions/{questionId}/instances/";

    public string InstancesGlobPrefix()
        => $"{_env}/projects/";

    public string MagicLinkTokenPath(string jti)
        => $"{_env}/tokens/jti/{jti}.json";

    public string DeviceTokenPath(string deviceTokenId)
        => $"{_env}/tokens/devices/{deviceTokenId}.json";

    public string AttachmentBlobPath(Guid responseId, string fileName)
        => $"{_env}/attachments/{responseId}/{Path.GetFileName(fileName)}";

    public string AdministratorsPath()
        => $"{_env}/config/administrators.json";
}
