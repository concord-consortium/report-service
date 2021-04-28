const parquet = require('parquetjs');

export interface AnswerData {
  // leaving out everything but the resource_url and run_key which is what we care about
  answer?: any;
  resource_url: string;
  run_key?: string;
}

export const schema = new parquet.ParquetSchema({
  submitted: { type: 'BOOLEAN', optional: true },
  run_key: { type: 'UTF8' },
  platform_user_id: { type: 'UTF8', optional: true },
  id: { type: 'UTF8' },
  context_id: { type: 'UTF8', optional: true },
  class_info_url: { type: 'UTF8', optional: true },
  platform_id: { type: 'UTF8', optional: true },
  resource_link_id: { type: 'UTF8', optional: true },
  type: { type: 'UTF8' },
  question_id: { type: 'UTF8' },
  source_key: { type: 'UTF8' },
  question_type: { type: 'UTF8' },
  tool_user_id: { type: 'UTF8' },
  answer: { type: 'UTF8' },
  resource_url: { type: 'UTF8' },
  remote_endpoint: { type: 'UTF8', optional: true },
  created: { type: 'UTF8' },
  tool_id: { type: 'UTF8' },
  version: { type: 'UTF8' },
});

export const parquetInfo = (directory: string, answer?: AnswerData | null, _runKey?: string, _resourceUrl?: string) => {
  let runKey, resourceUrl;
  if (answer) {
    runKey = answer.run_key;
    resourceUrl = answer.resource_url;
  } else {
    runKey = _runKey;
    resourceUrl = _resourceUrl;
  }
  if (!runKey || !resourceUrl) {
    throw Error(`Cannot create filename for ${runKey}`);
  }

  const filename = `${runKey}.parquet`;
  const folder = resourceUrl.replace(/[^a-z0-9]/g, "-");
  return {
    filename,
    key: `${directory}/${folder}/${filename}`
  }
}
