defmodule Plausible.Site.RateLimiter do
  @policy_for_non_existing_sites :deny
  @policy_on_rate_limiting_backend_error :allow

  @moduledoc """
  Thin wrapper around Hammer for rate limiting domain-specific events
  during the ingestion phase. Currently there are two policies
  on which the `allow/2` function operates:
    * `:allow`
    * `:deny`

  Rate Limiting buckets are configured per site (externally via the CRM).
  See: `Plausible.Site`

  To look up each site's configuration, the RateLimiter fetches
  a Site by domain using `Plausible.Cache` interface.

  The module defines two policies outside the regular bucket inspection:
    * when the the site is not found in cache: #{@policy_for_non_existing_sites}
    * when the underlying rate limiting mechanism returns
      an internal error: #{@policy_on_rate_limiting_backend_error}

  Each policy computation emits a single telemetry event.
  See: `policy_telemetry_event/1`
  """
  alias Plausible.Site
  alias Plausible.Site.Cache

  require Logger

  @spec allow?(String.t(), Keyword.t()) :: boolean()
  def allow?(domain, opts \\ []) do
    policy(domain, opts) == :allow
  end

  @spec key(String.t()) :: String.t()
  def key(domain) do
    "ingest:site:#{domain}"
  end

  @spec policy_telemetry_event(:allow | :deny) :: list(atom())
  def policy_telemetry_event(policy) do
    [:plausible, :ingest, :rate_limit, policy]
  end

  defp policy(domain, opts) do
    result =
      case Cache.get(domain, Keyword.get(opts, :cache_opts, [])) do
        nil ->
          @policy_for_non_existing_sites

        %Site{} = site ->
          check_rate_limit(site, opts)
      end

    :ok = emit_allowance_telemetry(result)
    result
  end

  defp check_rate_limit(%Site{ingest_rate_limit_threshold: nil}, _opts) do
    :allow
  end

  defp check_rate_limit(%Site{ingest_rate_limit_threshold: 0}, _opts) do
    :block
  end

  defp check_rate_limit(%Site{ingest_rate_limit_threshold: threshold} = site, opts)
       when is_integer(threshold) do
    key = Keyword.get(opts, :key, key(site.domain))
    scale_ms = site.ingest_rate_limit_scale_seconds * 1_000

    case Hammer.check_rate(key, scale_ms, threshold) do
      {:deny, _} ->
        :throttle

      {:allow, _} ->
        :allow

      {:error, reason} ->
        Logger.error(
          "Error checking rate limit for '#{key}': #{inspect(reason)}. Falling back to: #{@policy_on_rate_limiting_backend_error}"
        )

        @policy_on_rate_limiting_backend_error
    end
  end

  defp emit_allowance_telemetry(policy) do
    :telemetry.execute(policy_telemetry_event(policy), %{}, %{})
  end
end
