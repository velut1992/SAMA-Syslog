package com.supra.plugins;

import org.opensearch.action.search.SearchRequest;
import org.opensearch.action.search.SearchResponse;
import org.opensearch.action.support.IndicesOptions;
import org.opensearch.core.action.ActionListener;
import org.opensearch.core.rest.RestStatus;
import org.opensearch.core.xcontent.XContentBuilder;
import org.opensearch.index.query.QueryBuilders;
import org.opensearch.rest.BaseRestHandler;
import org.opensearch.rest.BytesRestResponse;
import org.opensearch.rest.RestChannel;
import org.opensearch.rest.RestRequest;
import org.opensearch.search.aggregations.AggregationBuilders;
import org.opensearch.search.aggregations.metrics.Cardinality;
import org.opensearch.search.builder.SearchSourceBuilder;
import org.opensearch.transport.client.node.NodeClient;

import java.util.List;

import static org.opensearch.rest.RestRequest.Method.GET;

/**
 * Exposes the validated license plus live device usage as JSON at
 * {@code GET /_supra/license} so it can be read from OpenSearch Dashboards
 * (Dev Tools console) without shell access or the vendor's private key.
 *
 * The license details come from the snapshot {@link LicenseValidatorPlugin}
 * published at startup. The device usage is computed on each call: a distinct
 * count (cardinality) of the {@code host} field across the {@code supra-*} log
 * indices over the last {@value #WINDOW}, i.e. devices that have actually sent
 * data recently. This is a soft check — it reports current vs licensed devices
 * and an over-limit flag; it does not block ingestion.
 */
public class RestSupraLicenseAction extends BaseRestHandler {

    // What counts as a "device" and over what window. Kept as constants so the
    // behaviour is explicit; promote to node settings if these ever need tuning.
    private static final String INDEX_PATTERN = "supra-*";
    private static final String HOST_FIELD = "host";
    private static final String TIMESTAMP_FIELD = "@timestamp";
    private static final String WINDOW = "24h";

    @Override
    public String getName() {
        return "supra_license_action";
    }

    @Override
    public List<Route> routes() {
        return List.of(new Route(GET, "/_supra/license"));
    }

    @Override
    protected RestChannelConsumer prepareRequest(RestRequest request, NodeClient client) {
        final LicenseInfo info = LicenseValidatorPlugin.publishedLicense();

        return channel -> {
            SearchSourceBuilder source = new SearchSourceBuilder()
                    .size(0)
                    .trackTotalHits(false)
                    .query(QueryBuilders.rangeQuery(TIMESTAMP_FIELD).gte("now-" + WINDOW))
                    .aggregation(AggregationBuilders.cardinality("active_devices").field(HOST_FIELD));

            SearchRequest searchRequest = new SearchRequest(INDEX_PATTERN)
                    .source(source)
                    // tolerate the indices not existing yet (fresh install)
                    .indicesOptions(IndicesOptions.lenientExpandOpen());

            client.search(searchRequest, new ActionListener<SearchResponse>() {
                @Override
                public void onResponse(SearchResponse response) {
                    Long activeDevices = null;
                    if (response.getAggregations() != null) {
                        Cardinality card = response.getAggregations().get("active_devices");
                        if (card != null) {
                            activeDevices = card.getValue();
                        }
                    }
                    send(channel, info, activeDevices, null);
                }

                @Override
                public void onFailure(Exception e) {
                    // Never fail the license report just because the usage query
                    // could not run (e.g. no indices, permissions). Report the
                    // license and surface the reason device usage is unavailable.
                    send(channel, info, null, e.getMessage());
                }
            });
        };
    }

    /** Build and send the combined license + device-usage JSON. */
    private static void send(RestChannel channel, LicenseInfo info, Long activeDevices, String usageError) {
        try {
            XContentBuilder builder = channel.newBuilder();
            builder.startObject();
            if (info == null) {
                // Defensive: the node only starts when validation succeeds.
                builder.field("status", "UNKNOWN");
                builder.field("message", "License details are not available.");
            } else {
                builder.field("customer", info.customer);
                builder.field("license_type", info.licenseType);
                builder.field("validity", info.validity);
                builder.field("status", info.status);
                builder.field("issued_at", info.issuedAt);
                builder.field("expires_at", info.expiresAt);
                builder.field("tier", info.tier);
                builder.field("max_nodes", info.maxNodes);

                // --- device limit + live usage ---
                if (info.maxDevices == null) {
                    builder.field("max_devices", "not specified");
                } else {
                    builder.field("max_devices", info.maxDevices);
                }
                builder.field("device_window", "last " + WINDOW);
                if (usageError != null) {
                    builder.field("active_devices", (Long) null);
                    builder.field("device_usage_error", usageError);
                } else {
                    builder.field("active_devices", activeDevices);
                    if (info.maxDevices != null && activeDevices != null) {
                        long remaining = info.maxDevices - activeDevices;
                        builder.field("devices_remaining", remaining < 0 ? 0 : remaining);
                        builder.field("over_limit", activeDevices > info.maxDevices);
                    }
                }

                builder.field("bound_to_machine", info.fingerprint);
                builder.field("signature_verified", info.signatureVerified);
            }
            builder.endObject();
            channel.sendResponse(new BytesRestResponse(RestStatus.OK, builder));
        } catch (Exception e) {
            try {
                channel.sendResponse(new BytesRestResponse(channel, e));
            } catch (Exception ignored) {
                // nothing more we can do
            }
        }
    }
}
