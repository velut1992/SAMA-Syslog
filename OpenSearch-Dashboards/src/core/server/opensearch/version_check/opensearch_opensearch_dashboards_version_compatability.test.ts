/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * The OpenSearch Contributors require contributions made to
 * this file be licensed under the Apache-2.0 license or a
 * compatible open source license.
 *
 * Any modifications Copyright OpenSearch Contributors. See
 * GitHub history for details.
 */

/*
 * Licensed to Elasticsearch B.V. under one or more contributor
 * license agreements. See the NOTICE file distributed with
 * this work for additional information regarding copyright
 * ownership. Elasticsearch B.V. licenses this file to you under
 * the Apache License, Version 2.0 (the "License"); you may
 * not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied.  See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */

import { opensearchVersionCompatibleWithOpenSearchDashboards } from './opensearch_opensearch_dashboards_version_compatability';

describe('plugins/opensearch', () => {
  describe('lib/is_opensearch_compatible_with_opensearch_dashboards', () => {
    describe('returns false', () => {
      it('when major is greater than Dashboards major', () => {
        expect(opensearchVersionCompatibleWithOpenSearchDashboards('1.0.0', '0.0.0')).toBe(false);
      });

      it('when major is less than Dashboards major', () => {
        expect(opensearchVersionCompatibleWithOpenSearchDashboards('0.0.0', '1.0.0')).toBe(false);
      });

      it('when majors are equal, but minor is less than Dashboards minor', () => {
        expect(opensearchVersionCompatibleWithOpenSearchDashboards('1.0.0', '1.1.0')).toBe(false);
      });

      it('when majors and minors are not equal, but the engine is on legacy version 6.10.3 and Dashboards is on 1.0.0', () => {
        expect(opensearchVersionCompatibleWithOpenSearchDashboards('6.10.3', '1.0.0')).toBe(false);
      });

      it('when majors and minors are not equal, but the engine is on legacy version 7.10.3 and Dashboards is on 1.0.0', () => {
        expect(opensearchVersionCompatibleWithOpenSearchDashboards('7.10.3', '1.0.0')).toBe(false);
      });

      it('when majors and minors are not equal, but the engine is on legacy version 8.0.0 and Dashboards is on 1.0.0', () => {
        expect(opensearchVersionCompatibleWithOpenSearchDashboards('8.0.0', '1.0.0')).toBe(false);
      });

      it('when majors and minors are not equal, but the engine is on legacy version 6.10.3 and Dashboards is on 2.0.0', () => {
        expect(opensearchVersionCompatibleWithOpenSearchDashboards('6.10.3', '2.0.0')).toBe(false);
      });

      it('when majors and minors are not equal, but the engine is on legacy version 7.10.3 and Dashboards is on 2.0.0', () => {
        expect(opensearchVersionCompatibleWithOpenSearchDashboards('7.10.3', '2.0.0')).toBe(false);
      });

      it('when majors and minors are not equal, but the engine is on legacy version 8.0.0 and Dashboards is on 2.0.0', () => {
        expect(opensearchVersionCompatibleWithOpenSearchDashboards('8.0.0', '2.0.0')).toBe(false);
      });

      it('when majors and minors are not equal, but the engine is on legacy version 6.10.3 and Dashboards is on 3.0.0', () => {
        expect(opensearchVersionCompatibleWithOpenSearchDashboards('6.10.3', '3.0.0')).toBe(false);
      });

      it('when majors and minors are not equal, but the engine is on legacy version 7.10.3 and Dashboards is on 3.0.0', () => {
        expect(opensearchVersionCompatibleWithOpenSearchDashboards('7.10.3', '3.0.0')).toBe(false);
      });

      it('when majors and minors are not equal, but the engine is on legacy version 8.0.0 and Dashboards is on 3.0.0', () => {
        expect(opensearchVersionCompatibleWithOpenSearchDashboards('8.0.0', '3.0.0')).toBe(false);
      });
    });

    describe('returns true', () => {
      it('when version numbers are the same', () => {
        expect(opensearchVersionCompatibleWithOpenSearchDashboards('1.1.1', '1.1.1')).toBe(true);
      });

      it('when majors are equal, and minor is greater than Dashboards minor', () => {
        expect(opensearchVersionCompatibleWithOpenSearchDashboards('1.1.0', '1.0.0')).toBe(true);
      });

      it('when majors and minors are equal, and patch is greater than Dashboards patch', () => {
        expect(opensearchVersionCompatibleWithOpenSearchDashboards('1.1.1', '1.1.0')).toBe(true);
      });

      it('when majors and minors are equal, but patch is less than Dashboards patch', () => {
        expect(opensearchVersionCompatibleWithOpenSearchDashboards('1.1.0', '1.1.1')).toBe(true);
      });

      it('when majors and minors are not equal, but the engine is on legacy version 7.10.2 and Dashboards is on 1.0.0', () => {
        expect(opensearchVersionCompatibleWithOpenSearchDashboards('7.10.2', '1.0.0')).toBe(true);
      });

      it('when majors and minors are not equal, but the engine is on legacy version 7.10.2 and Dashboards is on 1.0.1', () => {
        expect(opensearchVersionCompatibleWithOpenSearchDashboards('7.10.2', '1.0.1')).toBe(true);
      });

      it('when majors and minors are not equal, but the engine is on legacy version 7.10.2 and Dashboards is on 1.1.0', () => {
        expect(opensearchVersionCompatibleWithOpenSearchDashboards('7.10.2', '1.1.0')).toBe(true);
      });

      it('when majors and minors are not equal, but the engine is on legacy version 7.10.2 and Dashboards is on 2.0.0', () => {
        expect(opensearchVersionCompatibleWithOpenSearchDashboards('7.10.2', '2.0.0')).toBe(true);
      });

      it('when majors and minors are not equal, but the engine is on legacy version 7.10.2 and Dashboards is on 2.0.1', () => {
        expect(opensearchVersionCompatibleWithOpenSearchDashboards('7.10.2', '2.0.1')).toBe(true);
      });

      it('when majors and minors are not equal, but the engine is on legacy version 7.10.2 and Dashboards is on 2.1.0', () => {
        expect(opensearchVersionCompatibleWithOpenSearchDashboards('7.10.2', '2.1.0')).toBe(true);
      });

      it('when majors and minors are not equal, but the engine is on legacy version 7.10.2 and Dashboards is on 3.0.0', () => {
        expect(opensearchVersionCompatibleWithOpenSearchDashboards('7.10.2', '3.0.0')).toBe(true);
      });

      it('when majors and minors are not equal, but the engine is on legacy version 7.10.2 and Dashboards is on 3.0.1', () => {
        expect(opensearchVersionCompatibleWithOpenSearchDashboards('7.10.2', '3.0.1')).toBe(true);
      });

      it('when majors and minors are not equal, but the engine is on legacy version 7.10.2 and Dashboards is on 3.1.0', () => {
        expect(opensearchVersionCompatibleWithOpenSearchDashboards('7.10.2', '3.1.0')).toBe(true);
      });
    });
  });
});
