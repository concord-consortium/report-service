export type ILaraResourceType = 'Activity' | 'Sequence';

export interface IStandardLaraKeys {
  id: string;
  source_key: string;
}

export interface IPartialLaraAuthoredResource extends IStandardLaraKeys{
  url: string;
  author_email: string;
  type: ILaraResourceType;
}

export interface IPartialLaraRun extends IStandardLaraKeys{
  url: string;
  answers?: IPartialLaraAnswer[];
}

export interface IPartialLaraAnswer extends IStandardLaraKeys {
  question_key: string;
}
