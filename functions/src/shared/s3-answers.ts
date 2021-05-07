import { getHash } from "../auto-importer";

const parquet = require('parquetjs');

export interface AnswerMetadata {
  resource_url: string;
  // logged-in user
  platform_id?: string;
  resource_link_id?: string;
  platform_user_id?: string;
  // anonymous user
  run_key?: string;
}

export interface AnswerData extends AnswerMetadata {
  // leaving out everything but the resource_url and run_key which is what we care about
  answer?: any;
  report_state?: any;
  version?: any;
}

export const schema = new parquet.ParquetSchema({
  submitted: { type: 'BOOLEAN', optional: true },
  run_key: { type: 'UTF8', optional: true },
  platform_user_id: { type: 'UTF8', optional: true },
  id: { type: 'UTF8' },
  context_id: { type: 'UTF8', optional: true },
  class_info_url: { type: 'UTF8', optional: true },
  platform_id: { type: 'UTF8', optional: true },
  resource_link_id: { type: 'UTF8', optional: true },
  type: { type: 'UTF8', optional: true },
  question_id: { type: 'UTF8' },
  source_key: { type: 'UTF8' },
  question_type: { type: 'UTF8', optional: true },
  tool_user_id: { type: 'UTF8', optional: true },
  answer: { type: 'UTF8' },
  resource_url: { type: 'UTF8' },
  remote_endpoint: { type: 'UTF8', optional: true },
  created: { type: 'UTF8', optional: true },
  tool_id: { type: 'UTF8' },
  version: { type: 'UTF8', optional: true },
});

// replaces everything but alphanumeric chars with -
const escapeUrl = (url: string) => url.replace(/[^a-z0-9]/g, "-")

/**
 * Returns the filename and directory structure that the parquet file should end up in, given an answer.
 *
 * For a logged-in user launching from the portal (LARA or Activity Player):
 *  answers/[escaped_resource_id]/[platform_id]/[resource_link_id]/[platform_user_id].parquet
 *
 * For an anonymous user (LARA or AP):
 *  answers/[escaped_resource_id]/anonymous/no-resource-link/[run-key].parquet
 *
 * @param directory Top-level directory in S3 bucket (partitioned-answers)
 * @param answer Answer or metadata-only info
 */
export const parquetInfo = (directory: string, answer: AnswerMetadata) => {
  const escaped_resource_id = escapeUrl(answer.resource_url);
  let filename: string;
  if (escaped_resource_id && answer.platform_id && answer.resource_link_id && answer.platform_user_id) {
    filename = `${answer.platform_user_id}.parquet`;
    return {
      filename,
      key: `${directory}/${escaped_resource_id}/${escapeUrl(answer.platform_id)}/${answer.resource_link_id}/${filename}`
    };
  } else if (answer.run_key) {
    filename = `${answer.run_key}.parquet`;
    return {
      filename,
      key: `${directory}/${escaped_resource_id}/anonymous/no-resource-link/${filename}`
    };
  } else {
    throw Error(`Cannot create filename`);
  }
}

// returns just the part needed to identify the answer uniquely
export const getSyncDocId = (answer: AnswerData) => {
  if (answer.platform_id && answer.resource_link_id && answer.platform_user_id) {
    // urls don't need to be escaped because the document name will be hashed
    const ltiId = `${answer.platform_id}_${answer.resource_link_id}_${answer.platform_user_id}`;
    return getHash(ltiId);
  } else if (answer.run_key) {
    return answer.run_key;
  }
  return null;
}

// returns just the part needed to identify the answer uniquely
export const getAnswerMetadata = (answer: AnswerData) => {
  if (answer.resource_url && answer.platform_id && answer.resource_link_id && answer.platform_user_id) {
    return {
      resource_url: answer.resource_url,
      platform_id: answer.platform_id,
      resource_link_id: answer.resource_link_id,
      platform_user_id: answer.platform_user_id
    };
  } else if (answer.resource_url && answer.run_key) {
    return {
      resource_url: answer.resource_url,
      run_key: answer.run_key
    };
  }
  return null;
}
