using System.Diagnostics.CodeAnalysis;

namespace InteropExperiments;

public class ScanResult
{
    public required string Imb { get; set; }

    public required MailPhase MailPhase { get; set; }
}

/// <summary>
/// Well, enums might not be enough for this.
/// There's a complicated phrase and a potential hierarchy, so I'm representing this with a float-string pair.
/// </summary>
public class MailPhase
{
    private MailPhase(float value, string name)
    {
        Value = value;
        Name = name;
    }

    public float Value { get; }

    public string Name { get; }

    public override string ToString()
    {
        return Name;
    }

    public static bool TryFrom(string phaseName, [NotNullWhen(true)] out MailPhase? phase)
    {
        phase = null;
        if (Steps.TryGetValue(phaseName, out float value))
        {
            phase = new(value, phaseName);
            return true;
        }
        return false;
    }

    public static explicit operator MailPhase(string phase)
    {
        if (Steps.TryGetValue(phase, out float result))
        {
            return new(result, phase);
        }
        throw new InvalidCastException($"Unrecognized mail phase '{phase}'");
    }

    public static explicit operator MailPhase(float value)
    {
        return value switch
        {
            0 => Phase0,
            1 => Phase1,
            1.1F => Phase1a,
            1.2F => Phase1b,
            2 => Phase2,
            2.1F => Phase2a,
            2.2F => Phase2b,
            2.3F => Phase2c,
            3.1F => Phase3a,
            3.2F => Phase3b,
            3.3F => Phase3c,
            4.3F => Phase4c,
            10 => PARSProcessing,
            11 => FPARSProcessing,
            12 => Miscellaneous,
            13 => ForeignProcessing,
            _ => throw new InvalidCastException($"Unrecognized mail phase value {value}"),
        };
    }

    public static implicit operator string(MailPhase source)
    {
        return source.ToString();
    }

    public static bool operator ==(MailPhase a, MailPhase b)
    {
        return a.Equals(b);
    }

    public static bool operator !=(MailPhase a, MailPhase b)
    {
        return !a.Equals(b);
    }

    public static bool operator >(MailPhase a, MailPhase b)
    {
        return a.Value > b.Value;
    }

    public static bool operator >=(MailPhase a, MailPhase b)
    {
        return a.Value >= b.Value;
    }

    public static bool operator <(MailPhase a, MailPhase b)
    {
        return a.Value < b.Value;
    }

    public static bool operator <=(MailPhase a, MailPhase b)
    {
        return a.Value <= b.Value;
    }

    /// <inheritdoc />
    public override bool Equals(object? obj)
    {
        if (obj is MailPhase other)
        {
            return other.Value == Value
                && other.Name == Name;
        }
        return false;
    }

    /// <inheritdoc />
    public override int GetHashCode()
    {
        return HashCode.Combine(Value, Name);
    }

    public static IReadOnlyDictionary<string, float> Steps { get; } = new Dictionary<string, float>()
    {
        ["Phase 0 - Origin Processing Cancellation of Postage"] = 0,
        ["Phase 1 - Origin Processing"] = 1,
        ["Phase 1a - Origin Primary Processing"] = 1.1F,
        ["Phase 1b - Origin Secondary Processing"] = 1.2F,
        ["Phase 2 - Destination Processing"] = 2,
        ["Phase 2a - Destination MMP Processing"] = 2.1F,
        ["Phase 2b - Destination SCF Processing"] = 2.2F,
        ["Phase 2c - Destination Primary Processing"] = 2.3F,
        ["Phase 3a - Destination Secondary Processing"] = 3.1F,
        ["Phase 3b - Destination Box Mail Processing"] = 3.2F,
        ["Phase 3c - Destination Sequenced Carrier Sortation"] = 3.3F,
        ["Phase 4c - Delivery"] = 4.3F,
        ["PARS Processing"] = 10,
        ["FPARS Processing"] = 11,
        ["Miscellaneous"] = 12,
        ["Foreign Processing"] = 13,
    };

    public static MailPhase Phase0 { get; } = new(0, "Phase 0 - Origin Processing Cancellation of Postage");

    public static MailPhase Phase1 { get; } = new(1, "Phase 1 - Origin Processing");

    public static MailPhase Phase1a { get; } = new(1.1F, "Phase 1a - Origin Primary Processing");

    public static MailPhase Phase1b { get; } = new(1.2F, "Phase 1b - Origin Secondary Processing");

    public static MailPhase Phase2 { get; } = new(2, "Phase 2 - Destination Processing");

    public static MailPhase Phase2a { get; } = new(2.1F, "Phase 2a - Destination MMP Processing");

    public static MailPhase Phase2b { get; } = new(2.2F, "Phase 2b - Destination SCF Processing");

    public static MailPhase Phase2c { get; } = new(2.3F, "Phase 2c - Destination Primary Processing");

    public static MailPhase Phase3a { get; } = new(3.1F, "Phase 3a - Destination Secondary Processing");

    public static MailPhase Phase3b { get; } = new(3.2F, "Phase 3b - Destination Box Mail Processing");

    public static MailPhase Phase3c { get; } = new(3.3F, "Phase 3c - Destination Sequenced Carrier Sortation");

    public static MailPhase Phase4c { get; } = new(4.3F, "Phase 4c - Delivery");

    // TODO : Are these ones in the right order?

    public static MailPhase PARSProcessing { get; } = new(10, "PARS Processing");

    public static MailPhase FPARSProcessing { get; } = new(11, "FPARS Processing");

    public static MailPhase Miscellaneous { get; } = new(12, "Miscellaneous");

    public static MailPhase ForeignProcessing { get; } = new(13, "Foreign Processing");
}
