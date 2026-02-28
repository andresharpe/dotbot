using Azure.Identity;
using Azure.Security.KeyVault.Keys;
using Azure.Security.KeyVault.Keys.Cryptography;
using Dotbot.Server.Models;
using Microsoft.Extensions.Options;
using Microsoft.IdentityModel.Tokens;
using System.Security.Cryptography;
using System.Text;

namespace Dotbot.Server.Services;

public class JwtSigningKeyProvider
{
    private readonly AuthSettings _settings;
    private readonly ILogger<JwtSigningKeyProvider> _logger;

    private SigningCredentials? _cachedCredentials;
    private TokenValidationParameters? _cachedValidation;
    private DateTime _cacheExpiry = DateTime.MinValue;
    private readonly SemaphoreSlim _lock = new(1, 1);

    public JwtSigningKeyProvider(IOptions<AuthSettings> settings, ILogger<JwtSigningKeyProvider> logger)
    {
        _settings = settings.Value;
        _logger = logger;
    }

    public async Task<SigningCredentials> GetSigningCredentialsAsync()
    {
        await EnsureCacheAsync();
        return _cachedCredentials!;
    }

    public async Task<TokenValidationParameters> GetValidationParametersAsync()
    {
        await EnsureCacheAsync();
        return _cachedValidation!;
    }

    private async Task EnsureCacheAsync()
    {
        if (_cachedCredentials is not null && DateTime.UtcNow < _cacheExpiry)
            return;

        await _lock.WaitAsync();
        try
        {
            if (_cachedCredentials is not null && DateTime.UtcNow < _cacheExpiry)
                return;

            if (!string.IsNullOrEmpty(_settings.KeyVaultUri))
            {
                await LoadFromKeyVaultAsync();
            }
            else if (!string.IsNullOrEmpty(_settings.JwtSigningKey))
            {
                LoadFromSymmetricKey();
            }
            else
            {
                throw new InvalidOperationException(
                    "Neither Auth:KeyVaultUri nor Auth:JwtSigningKey is configured.");
            }

            _cacheExpiry = DateTime.UtcNow.AddHours(1);
        }
        finally
        {
            _lock.Release();
        }
    }

    private async Task LoadFromKeyVaultAsync()
    {
        _logger.LogInformation("Loading JWT signing key from Key Vault: {Uri}", _settings.KeyVaultUri);

        var credential = new DefaultAzureCredential();
        var keyClient = new KeyClient(new Uri(_settings.KeyVaultUri!), credential);
        var keyResponse = await keyClient.GetKeyAsync(_settings.KeyName);
        var key = keyResponse.Value;

        // Public key for validation (ToRSA only returns public key material from Key Vault)
        var rsaPublicKey = key.Key.ToRSA();
        var publicSecurityKey = new RsaSecurityKey(rsaPublicKey) { KeyId = key.Id.ToString() };

        // For signing, use CryptographyClient to perform operations remotely in Key Vault
        var cryptoClient = new CryptographyClient(key.Id, credential);
        var signingKey = new RsaSecurityKey(rsaPublicKey) { KeyId = key.Id.ToString() };
        signingKey.CryptoProviderFactory = new KeyVaultCryptoProviderFactory(cryptoClient);

        _cachedCredentials = new SigningCredentials(signingKey, SecurityAlgorithms.RsaSha256);
        _cachedValidation = new TokenValidationParameters
        {
            ValidateIssuerSigningKey = true,
            IssuerSigningKey = publicSecurityKey,
            ValidateIssuer = true,
            ValidIssuer = _settings.JwtIssuer,
            ValidateAudience = true,
            ValidAudience = _settings.JwtAudience,
            ValidateLifetime = true,
            ClockSkew = TimeSpan.FromMinutes(1)
        };
    }

    private void LoadFromSymmetricKey()
    {
        _logger.LogInformation("Using symmetric JWT signing key (development mode)");

        var keyBytes = Encoding.UTF8.GetBytes(_settings.JwtSigningKey!);
        if (keyBytes.Length < 32)
        {
            // Pad to minimum 256 bits for HS256
            keyBytes = SHA256.HashData(keyBytes);
        }
        var securityKey = new SymmetricSecurityKey(keyBytes);

        _cachedCredentials = new SigningCredentials(securityKey, SecurityAlgorithms.HmacSha256);
        _cachedValidation = new TokenValidationParameters
        {
            ValidateIssuerSigningKey = true,
            IssuerSigningKey = securityKey,
            ValidateIssuer = true,
            ValidIssuer = _settings.JwtIssuer,
            ValidateAudience = true,
            ValidAudience = _settings.JwtAudience,
            ValidateLifetime = true,
            ClockSkew = TimeSpan.FromMinutes(1)
        };
    }
}

/// <summary>
/// Custom CryptoProviderFactory that delegates signing operations to Azure Key Vault
/// via the CryptographyClient, since Key Vault RSA keys don't expose private key material locally.
/// </summary>
internal class KeyVaultCryptoProviderFactory : CryptoProviderFactory
{
    private readonly CryptographyClient _cryptoClient;

    public KeyVaultCryptoProviderFactory(CryptographyClient cryptoClient)
    {
        _cryptoClient = cryptoClient;
    }

    public override SignatureProvider CreateForSigning(SecurityKey key, string algorithm)
    {
        return new KeyVaultSignatureProvider(key, algorithm, _cryptoClient, willCreateSignatures: true);
    }

    public override SignatureProvider CreateForVerifying(SecurityKey key, string algorithm)
    {
        return new KeyVaultSignatureProvider(key, algorithm, _cryptoClient, willCreateSignatures: false);
    }

    public override bool IsSupportedAlgorithm(string algorithm, SecurityKey key)
    {
        return algorithm == SecurityAlgorithms.RsaSha256;
    }

    public override void ReleaseSignatureProvider(SignatureProvider signatureProvider) { }
}

/// <summary>
/// SignatureProvider that signs/verifies using Azure Key Vault CryptographyClient.
/// </summary>
internal class KeyVaultSignatureProvider : SignatureProvider
{
    private readonly CryptographyClient _cryptoClient;

    public KeyVaultSignatureProvider(SecurityKey key, string algorithm, CryptographyClient cryptoClient, bool willCreateSignatures)
        : base(key, algorithm)
    {
        _cryptoClient = cryptoClient;
        WillCreateSignatures = willCreateSignatures;
    }

    public override byte[] Sign(byte[] input)
    {
        var result = _cryptoClient.SignData(SignatureAlgorithm.RS256, input);
        return result.Signature;
    }

    public override bool Verify(byte[] input, byte[] signature)
    {
        var result = _cryptoClient.VerifyData(SignatureAlgorithm.RS256, input, signature);
        return result.IsValid;
    }

    public override bool Verify(byte[] input, int inputOffset, int inputLength, byte[] signature, int signatureOffset, int signatureLength)
    {
        var data = new byte[inputLength];
        Buffer.BlockCopy(input, inputOffset, data, 0, inputLength);
        var sig = new byte[signatureLength];
        Buffer.BlockCopy(signature, signatureOffset, sig, 0, signatureLength);
        return Verify(data, sig);
    }

    protected override void Dispose(bool disposing) { }
}
