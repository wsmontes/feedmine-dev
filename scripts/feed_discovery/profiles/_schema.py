from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class SourceConfig:
    """Configuracao de uma fonte para um pais especifico."""
    priority: int                             # 1 = mais importante
    enabled: bool = True
    params: dict[str, str] = field(default_factory=dict)
    min_results: int = 3                      # abaixo disso por N rodadas -> degraded
    max_results: int = 50                     # limite por query
    timeout: int = 15                         # segundos


@dataclass
class SourceMetrics:
    """Metricas acumuladas de performance de uma fonte."""
    total_calls: int = 0
    total_results: int = 0
    success_count: int = 0
    failure_count: int = 0
    consecutive_failures: int = 0             # zerado a cada probe bem-sucedido
    total_latency_ms: float = 0.0
    last_probe: str = ""                      # ISO timestamp

    @property
    def success_rate(self) -> float:
        if self.total_calls == 0:
            return 1.0
        return self.success_count / self.total_calls

    @property
    def avg_results(self) -> float:
        if self.total_calls == 0:
            return 0.0
        return self.total_results / self.total_calls

    @property
    def avg_latency_ms(self) -> float:
        if self.total_calls == 0:
            return 0.0
        return self.total_latency_ms / self.total_calls


@dataclass
class CountryProfile:
    """Perfil de internet de um pais -- define quais fontes usar e como."""
    country: str                              # "nigeria"

    # Demografia digital
    internet_penetration: float = 0.0         # 0.55 = 55%
    dominant_platforms: list[str] = field(default_factory=list)
    languages: list[str] = field(default_factory=list)

    # Fontes ativas com prioridade e config
    sources: dict[str, SourceConfig] = field(default_factory=dict)

    # Descobertas locais
    local_directories: list[str] = field(default_factory=list)
    media_domains: list[str] = field(default_factory=list)

    # Aprendizado
    disabled_sources: set[str] = field(default_factory=set)
    source_performance: dict[str, SourceMetrics] = field(default_factory=dict)

    # Metadata
    generated_at: str = ""                    # ISO timestamp
    generation_version: int = 1
