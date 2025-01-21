namespace InteropExperiments;

public class ScanResult
{
    public required string Imb { get; set; }

    public required MailPhase MailPhase { get; set; }
}

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

    public static explicit operator MailPhase(string phase)
    {
        if (Steps.TryGetValue(phase, out MailPhase? result))
        {
            return result;
        }
        throw new InvalidCastException($"Unrecognized mail phase '{phase}'");
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

    public static IReadOnlyDictionary<string, MailPhase> Steps { get; } = new Dictionary<string, MailPhase>()
    {
        ["Phase 0 - Origin Processing Cancellation of Postage"] = Phase0!,
        ["Phase 1 - Origin Processing"] = Phase1!,
        ["Phase 1a - Origin Primary Processing"] = Phase1a!,
        ["Phase 1b - Origin Secondary Processing"] = Phase1b!,
        ["Phase 2 - Destination Processing"] = Phase2!,
        ["Phase 2a - Destination MMP Processing"] = Phase2a!,
        ["Phase 2b - Destination SCF Processing"] = Phase2b!,
        ["Phase 2c - Destination Primary Processing"] = Phase2c!,
        ["Phase 3c- Destination Sequenced Carrier Sortation"] = Phase3!,
        ["Phase 3a - Destination Secondary Processing"] = Phase3a!,
        ["Phase 3b - Destination Box Mail Processing"] = Phase3b!,
        ["Phase 3c - Destination Sequenced Carrier Sortation"] = Phase3c!,
        ["Phase 4c - Delivery"] = Phase4c!,
        ["PARS Processing"] = PARSProcessing!,
        ["FPARS Processing"] = FPARSProcessing!,
        ["Miscellaneous"] = Miscellaneous!,
        ["Foreign Processing"] = ForeignProcessing!,
    };

    public static MailPhase Phase0 { get; } = new(0, "Phase 0 - Origin Processing Cancellation of Postage");

    public static MailPhase Phase1 { get; } = new(1, "Phase 1 - Origin Processing");

    public static MailPhase Phase1a { get; } = new(1.1F, "Phase 1a - Origin Primary Processing");

    public static MailPhase Phase1b { get; } = new(1.2F, "Phase 1b - Origin Secondary Processing");

    public static MailPhase Phase2 { get; } = new(2, "Phase 2 - Destination Processing");

    public static MailPhase Phase2a { get; } = new(2.1F, "Phase 2a - Destination MMP Processing");

    public static MailPhase Phase2b { get; } = new(2.2F, "Phase 2b - Destination SCF Processing");

    public static MailPhase Phase2c { get; } = new(2.3F, "Phase 2c - Destination Primary Processing");

    public static MailPhase Phase3 { get; } = new(3, "Phase 3c- Destination Sequenced Carrier Sortation");

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
